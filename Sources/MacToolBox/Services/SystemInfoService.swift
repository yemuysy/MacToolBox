import Darwin
import Foundation

/// 系统信息服务：CPU/内存/磁盘实时使用率 + 硬件信息
final class SystemInfoService: ObservableObject, @unchecked Sendable {
    static let shared = SystemInfoService()

    @Published private(set) var snapshot: SystemSnapshot = SystemSnapshot.empty

    /// 用于计算 CPU 使用率差值
    private var lastCPU: host_cpu_load_info = host_cpu_load_info()
    private var lastUpdateTime: Date = .distantPast
    private var hasFirstCPUSample = false

    /// 网速采样差值
    private var lastNetIn: UInt64 = 0
    private var lastNetOut: UInt64 = 0
    private var lastNetTime: Date = .distantPast

    /// SMC 温度读取（Apple Silicon 可能返回 nil）
    private var smc: SMCReader?

    /// 温度 EMA 平滑值（指数移动平均，新值权重 0.3）。
    /// 进一步抹平核心门控导致的偶发跳变；非 nil 表示已锁定稳定温度。
    private var smoothedTemp: Double?

    /// 历史点上限（约 2 分钟 @ 2s）
    private let historyMax = 60

    /// 主轮询（CPU/内存/网络/磁盘）间隔
    private let pollInterval: TimeInterval = 2.0
    /// 温度读取间隔（SMC 内核调用开销大，温度平滑后可降低频率）
    private let tempInterval: TimeInterval = 5.0

    private var timer: Timer?
    private var tempTimer: Timer?

    /// 温度专用串行队列：SMC 内核调用（含 usleep 重试）开销大，必须移出主线程；
    /// 同时串行化以保证 EMA 平滑状态（smoothedTemp）在队列内独占访问，避免数据竞争。
    private let tempQueue = DispatchQueue(label: "com.yemu.mactoolbox.temp")

    private init() {}

    struct SystemSnapshot: Equatable {
        var cpuUsage: Double          // 0~100
        var memoryUsed: Double        // bytes
        var memoryTotal: Double       // bytes
        var memoryUsage: Double       // 0~100
        var networkDown: Double       // bytes/s
        var networkUp: Double         // bytes/s
        var temperature: Double?      // °C，nil 表示设备不支持（多核心 die 平均，EMA 平滑）
        var temperatureHottest: Double? // °C，最热核心温度（nil 表示不支持）
        var disks: [DiskUsage]
        var batteryCycleCount: Int
        var batteryHealth: String
        var serialNumber: String
        var modelIdentifier: String
        var osVersion: String
        var uptimeSeconds: Double

        // 历史环形缓冲（用于趋势图），最多 historyMax 个点
        var cpuHistory: [Double]
        var memHistory: [Double]
        var netDownHistory: [Double]
        var netUpHistory: [Double]
        var tempHistory: [Double]     // 不支持时存 -1 占位

        static let empty = SystemSnapshot(
            cpuUsage: 0, memoryUsed: 0, memoryTotal: 0, memoryUsage: 0,
            networkDown: 0, networkUp: 0, temperature: nil, temperatureHottest: nil,
            disks: [], batteryCycleCount: 0, batteryHealth: "",
            serialNumber: "", modelIdentifier: "", osVersion: "", uptimeSeconds: 0,
            cpuHistory: [], memHistory: [], netDownHistory: [], netUpHistory: [], tempHistory: []
        )
    }

    struct DiskUsage: Identifiable, Equatable {
        let id: String
        let mountPoint: String
        let volumeName: String
        let usedBytes: Int64
        let totalBytes: Int64
        var usagePercent: Double {
            totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0
        }
    }

    func start() {
        // 初始化硬件信息（一次性）
        smc = SMCReader()
        refreshHardware()
        update()
        updateTemperature()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.update()
        }
        tempTimer = Timer.scheduledTimer(withTimeInterval: tempInterval, repeats: true) { [weak self] _ in
            self?.updateTemperature()
        }
        // 给予系统调度弹性，避免温度轮询抢占主线程时间片
        tempTimer?.tolerance = 2.0
        Logger.shared.info("SystemInfoService started, smc available: \(smc != nil)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tempTimer?.invalidate()
        tempTimer = nil
    }

    // MARK: - Implementation

    private func refreshHardware() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cycle = self?.readBatteryCycleCount() ?? 0
            let health = self?.readBatteryHealth() ?? ""
            let serial = self?.readSerialNumber() ?? ""
            let model = self?.readModelIdentifier() ?? ""
            let osVer = self?.readOSVersion() ?? ""

            DispatchQueue.main.async {
                guard var snap = self?.snapshot else { return }
                snap.batteryCycleCount = cycle
                snap.batteryHealth = health
                snap.serialNumber = serial
                snap.modelIdentifier = model
                snap.osVersion = osVer
                self?.snapshot = snap
            }
        }
    }

    private func update() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let cpu = self.readCPUUsage()
            let mem = self.readMemoryUsage()
            let disks = self.readDiskUsages()
            let uptime = self.readUptime()
            let net = self.readNetworkRate()

            DispatchQueue.main.async {
                var snap = self.snapshot
                snap.cpuUsage = cpu
                snap.memoryUsed = mem.used
                snap.memoryTotal = mem.total
                snap.memoryUsage = mem.usage
                snap.networkDown = net.down
                snap.networkUp = net.up

                snap.disks = disks
                snap.uptimeSeconds = uptime

                // 追加历史（环形缓冲）
                snap.cpuHistory = Self.append(snap.cpuHistory, cpu, max: self.historyMax)
                snap.memHistory = Self.append(snap.memHistory, mem.usage, max: self.historyMax)
                snap.netDownHistory = Self.append(snap.netDownHistory, net.down, max: self.historyMax)
                snap.netUpHistory = Self.append(snap.netUpHistory, net.up, max: self.historyMax)

                self.snapshot = snap
            }
        }
    }

    /// 温度更新（独立于主轮询，低频读取 SMC）。
    /// SMC 读取在后台串行队列进行，彻底避免阻塞主线程（此前每 5s 在主线程同步调用内核接口）。
    private func updateTemperature() {
        tempQueue.async { [weak self] in
            guard let self = self, let smc = self.smc else { return }

            // 后台读取：平均值 + 最热核心（各遍历约 30 个温度键，含重试）
            let rawAvg = smc.cpuTemperature()
            let rawHot = smc.hottestCoreTemperature()

            guard let avg = rawAvg else {
                // 读不到时不更新，保留上一帧温度，避免 UI 闪「—」
                return
            }
            let hot = rawHot ?? avg

            // EMA 时间平滑：进一步抹平核心门控进出导致的偶发跳变
            let smoothed: Double
            if let prev = self.smoothedTemp {
                smoothed = prev * 0.7 + avg * 0.3
            } else {
                smoothed = avg
            }
            self.smoothedTemp = smoothed

            // 历史点保持 2s 频率对齐：在主轮询之间补点，趋势图更平滑
            DispatchQueue.main.async {
                var snap = self.snapshot
                snap.temperature = smoothed
                snap.temperatureHottest = hot
                snap.tempHistory = Self.append(snap.tempHistory, smoothed, max: self.historyMax)
                self.snapshot = snap
            }
        }
    }

    /// 环形追加：超过上限时丢弃最旧的点
    private static func append(_ arr: [Double], _ value: Double, max: Int) -> [Double] {
        var next = arr
        next.append(value)
        if next.count > max {
            next.removeFirst(next.count - max)
        }
        return next
    }

    // MARK: - Network

    /// 采样所有非回环、已启用接口的总收发字节，返回当前速率（bytes/s）
    private func readNetworkRate() -> (down: Double, up: Double) {
        let (totalIn, totalOut) = readNetworkTotals()
        let now = Date()

        defer {
            lastNetIn = totalIn
            lastNetOut = totalOut
            lastNetTime = now
        }

        // 首次采样无基准，无法算速率
        guard lastNetTime != .distantPast else { return (0, 0) }

        let interval = now.timeIntervalSince(lastNetTime)
        guard interval > 0.1 else { return (0, 0) }

        let down = max(0, Double(totalIn - lastNetIn) / interval)
        let up = max(0, Double(totalOut - lastNetOut) / interval)
        return (down, up)
    }

    private func readNetworkTotals() -> (down: UInt64, up: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var down: UInt64 = 0
        var up: UInt64 = 0
        var ptr = ifaddr
        while let safe = ptr {
            let flags = safe.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if isUp, !isLoopback, let data = safe.pointee.ifa_data {
                let ifData = data.bindMemory(to: if_data.self, capacity: 1)
                down += UInt64(ifData.pointee.ifi_ibytes)
                up += UInt64(ifData.pointee.ifi_obytes)
            }
            ptr = safe.pointee.ifa_next
        }
        return (down, up)
    }

    // MARK: - CPU

    private func readCPUUsage() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let cur = info
        let prev = lastCPU
        lastCPU = cur

        // 首次采样：lastCPU 为零值，差值无意义，跳过本轮
        if !hasFirstCPUSample {
            hasFirstCPUSample = true
            return 0
        }

        let user = Double(cur.cpu_ticks.0 - prev.cpu_ticks.0)
        let system = Double(cur.cpu_ticks.1 - prev.cpu_ticks.1)
        let idle = Double(cur.cpu_ticks.2 - prev.cpu_ticks.2)
        let nice = Double(cur.cpu_ticks.3 - prev.cpu_ticks.3)

        let total = user + system + idle + nice
        if total <= 0 { return 0 }
        return min(100, (user + system + nice) / total * 100)
    }

    // MARK: - Memory

    private func readMemoryUsage() -> (used: Double, total: Double, usage: Double) {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        if pageSize == 0 { pageSize = 4096 }

        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }

        // 总内存
        var totalBytes: UInt64 = 0
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        var len = MemoryLayout<UInt64>.size
        sysctl(&mib, 2, &totalBytes, &len, nil, 0)
        let total = Double(totalBytes)

        let active = Double(stats.active_count) * Double(pageSize)
        let wired = Double(stats.wire_count) * Double(pageSize)
        let compressed = Double(stats.compressor_page_count) * Double(pageSize)
        let used = active + wired + compressed
        let usage = total > 0 ? used / total * 100 : 0
        return (used, total, usage)
    }

    // MARK: - Disks

    private func readDiskUsages() -> [DiskUsage] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsInternalKey],
            options: []
        ) ?? []

        return urls.compactMap { url -> DiskUsage? in
            guard let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsInternalKey
            ]) else { return nil }

            let total = Int64(values.volumeTotalCapacity ?? 0)
            let available = Int64(values.volumeAvailableCapacity ?? 0)
            guard total > 0 else { return nil }
            let used = total - available
            return DiskUsage(
                id: url.path,
                mountPoint: url.path,
                volumeName: values.volumeName ?? url.lastPathComponent,
                usedBytes: used,
                totalBytes: total
            )
        }
    }

    // MARK: - Hardware info

    private func readBatteryCycleCount() -> Int {
        let result = ShellExecutor.runShell("ioreg -rn AppleSmartBattery | grep -i 'CycleCount' | awk -F'= ' '{print $2}' | head -n1")
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func readBatteryHealth() -> String {
        let result = ShellExecutor.runShell("ioreg -rn AppleSmartBattery | grep -i 'PermanentFailureStatus' | awk -F'= ' '{print $2}' | head -n1")
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == "0" { return "正常" }
        return raw.isEmpty ? "无电池" : "异常"
    }

    private func readSerialNumber() -> String {
        let result = ShellExecutor.runShell("ioreg -l | grep -i 'IOPlatformSerialNumber' | awk -F'\"' '{print $4}' | head -n1")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readModelIdentifier() -> String {
        let result = ShellExecutor.runShell("sysctl -n hw.model")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readOSVersion() -> String {
        let result = ShellExecutor.runShell("sw_vers -productVersion")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readUptime() -> Double {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let now = Date().timeIntervalSince1970
        if sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 {
            return max(0, now - Double(bootTime.tv_sec))
        }
        return 0
    }
}
