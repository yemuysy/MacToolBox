import Foundation
import DiskArbitration
import CoreFoundation

/// 磁盘挂载服务
///
/// 监听磁盘插拔事件刷新列表，并提供挂载到指定路径的能力。
final class DiskMountService: ObservableObject, @unchecked Sendable {
    static let shared = DiskMountService()

    @Published private(set) var diskList: [DiskInfo] = []

    private var session: DASession?
    private let queue = DispatchQueue(label: "com.yemu.mactoolbox.diskmount")
    private var bootDiskBSD: String?
    private var isStarted = false

    private init() {}

    // MARK: - Public

    /// 首次进入磁盘 Tab 时调用（delayed start，降低常驻内存）
    func start() {
        guard !isStarted else { return }
        isStarted = true
        Logger.shared.info("DiskMountService starting")
        bootDiskBSD = queryBootDiskBSDName()
        setupDiskArbitration()
        refreshDiskList()
        // 启动 5 秒后尝试把记忆过的卷重新挂回原路径（等磁盘枚举稳定）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.restoreRememberedMounts()
        }
    }

    /// 开机/启动时，把此前挂载过的卷按记忆的路径重新挂上
    func restoreRememberedMounts() {
        let remembered = ConfigStore.shared.allMountPoints()
        guard !remembered.isEmpty else { return }
        queue.async { [weak self] in
            let connected = self?.collectDiskInfos() ?? []
            let connectedNames = Set(connected.compactMap { $0.volumeName })
            for (volumeName, path) in remembered {
                guard connectedNames.contains(volumeName) else { continue }
                guard !(self?.isVolumeMounted(volumeName: volumeName) ?? false) else { continue }
                Logger.shared.info("Restore mount: \(volumeName) -> \(path)")
                _ = self?.mountVolume(volumeName: volumeName, mountPoint: path)
            }
        }
    }

    /// 列出所有当前连接的磁盘
    struct DiskInfo: Identifiable, Equatable {
        let id: String          // BSD name, e.g. "disk2"
        let bsdName: String
        let volumeName: String?
        let fileSystem: String?
        let isMounted: Bool
        let mountPoint: String?
        let sizeBytes: Int64
        let isBootDisk: Bool

        var isSystemVolume: Bool {
            guard let mp = mountPoint?.lowercased() else { return false }
            let systemPaths = ["/system/", "/system/volumes/", "/private/", "/dev/"]
            if systemPaths.contains(where: { mp.hasPrefix($0) }) { return true }
            guard let vname = volumeName?.lowercased() else { return false }
            let systemNames = ["preboot", "xart", "vm", "update", "recovery", "iscpreboot", "apfsdata", "apfsboot"]
            return systemNames.contains(where: { vname.contains($0) })
        }
    }

    /// 挂载结果：成功时携带实际挂载点（可能 fallback 到 /Volumes/卷名）
    struct MountResult {
        let success: Bool
        let actualMountPoint: String?
        let usedFallback: Bool
        let errorMessage: String?
    }

    /// 挂载指定卷名，可选指定挂载点；指定路径失败时自动 fallback 到默认路径
    @discardableResult
    func mountVolume(volumeName: String, mountPoint: String? = nil) -> MountResult {
        guard let bsd = findBSDName(forVolumeName: volumeName) else {
            Logger.shared.warning("Volume \(volumeName) not found")
            return MountResult(success: false, actualMountPoint: nil, usedFallback: false, errorMessage: "未找到卷 \(volumeName)")
        }
        return mountDevice(bsdName: bsd, volumeName: volumeName, mountPoint: mountPoint)
    }

    /// 卸载指定卷名
    @discardableResult
    func unmountVolume(volumeName: String) -> Bool {
        guard let bsd = findBSDName(forVolumeName: volumeName) else { return false }
        let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["unmount", bsd])
        if result.exitCode == 0 {
            Logger.shared.info("Unmounted \(volumeName) (\(bsd))")
            refreshDiskList()
            return true
        } else {
            Logger.shared.error("Unmount failed: \(result.stderr)")
            return false
        }
    }

    // MARK: - 列表刷新

    /// 手动刷新磁盘列表
    func refreshDiskList() {
        queue.async { [weak self] in
            let infos = self?.collectDiskInfos() ?? []
            DispatchQueue.main.async {
                self?.diskList = infos
            }
        }
    }

    // MARK: - Private

    private func setupDiskArbitration() {
        let session = DASessionCreate(kCFAllocatorDefault)
        guard let session = session else {
            Logger.shared.error("Failed to create DASession")
            return
        }
        DASessionSetDispatchQueue(session, queue)

        let callback: DADiskAppearedCallback = { _, context in
            guard let context = context else { return }
            let service = Unmanaged<DiskMountService>.fromOpaque(context).takeUnretainedValue()
            service.handleDiskAppeared()
        }

        DARegisterDiskAppearedCallback(
            session,
            nil,
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        let disappearedCallback: DADiskDisappearedCallback = { _, context in
            guard let context = context else { return }
            let service = Unmanaged<DiskMountService>.fromOpaque(context).takeUnretainedValue()
            service.handleDiskDisappeared()
        }

        DARegisterDiskDisappearedCallback(
            session,
            nil,
            disappearedCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        self.session = session
    }

    private func handleDiskAppeared() {
        Logger.shared.info("Disk appeared event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshDiskList()
        }
    }

    private func handleDiskDisappeared() {
        Logger.shared.info("Disk disappeared event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshDiskList()
        }
    }

    private func mountDevice(bsdName: String, volumeName: String?, mountPoint: String? = nil) -> MountResult {
        let targetPoint = mountPoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPoint = "/Volumes/\(volumeName ?? bsdName)"

        // 没指定路径（或空）→ 按默认路径挂载，这是正常行为，不算 fallback
        guard let point = targetPoint, !point.isEmpty else {
            let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["mount", bsdName])
            if result.exitCode == 0 {
                let actual = findCurrentMountPoint(bsdName: bsdName) ?? fallbackPoint
                Logger.shared.info("Mounted \(bsdName) at default location \(actual)")
                DispatchQueue.main.async { self.refreshDiskList() }
                return MountResult(success: true, actualMountPoint: actual, usedFallback: false, errorMessage: nil)
            } else {
                Logger.shared.error("Default mount failed for \(bsdName): \(result.stderr)")
                return MountResult(success: false, actualMountPoint: nil, usedFallback: false,
                                   errorMessage: result.stderr.isEmpty ? "挂载失败" : result.stderr)
            }
        }

        // 用户显式指定了自定义路径 → 尝试 -mountPoint
        _ = ShellExecutor.run("/bin/mkdir", arguments: ["-p", point])
        let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["mount", "-mountPoint", point, bsdName])
        if result.exitCode == 0 {
            Logger.shared.info("Mounted \(bsdName) at \(point)")
            DispatchQueue.main.async { self.refreshDiskList() }
            return MountResult(success: true, actualMountPoint: point, usedFallback: false, errorMessage: nil)
        }
        Logger.shared.warning("Mount \(bsdName) at \(point) failed: \(result.stderr). Trying default fallback.")

        // 指定路径失败 → fallback 到默认路径（这才是真正的 fallback）
        let fallbackResult = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["mount", bsdName])
        if fallbackResult.exitCode == 0 {
            let actual = findCurrentMountPoint(bsdName: bsdName) ?? fallbackPoint
            Logger.shared.info("Mounted \(bsdName) at default location (fallback) \(actual)")
            DispatchQueue.main.async { self.refreshDiskList() }
            return MountResult(
                success: true,
                actualMountPoint: actual,
                usedFallback: true,
                errorMessage: "指定路径不可挂载，已自动挂到：\(actual)"
            )
        } else {
            Logger.shared.error("Mount failed for \(bsdName): \(fallbackResult.stderr)")
            return MountResult(
                success: false,
                actualMountPoint: nil,
                usedFallback: false,
                errorMessage: fallbackResult.stderr.isEmpty ? "挂载失败" : fallbackResult.stderr
            )
        }
    }

    private func findCurrentMountPoint(bsdName: String) -> String? {
        let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["info", "-plist", bsdName])
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let point = plist["MountPoint"] as? String else {
            return nil
        }
        return point
    }

    private func findBSDName(forVolumeName volumeName: String) -> String? {
        let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["list", "-plist"])
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return nil
        }

        for entry in allDisksAndPartitions {
            if let vname = entry["VolumeName"] as? String, vname == volumeName,
               let bsd = entry["DeviceIdentifier"] as? String {
                return bsd
            }
            if let parts = entry["Partitions"] as? [[String: Any]] {
                for part in parts {
                    if let vname = part["VolumeName"] as? String, vname == volumeName,
                       let bsd = part["DeviceIdentifier"] as? String {
                        return bsd
                    }
                }
            }
        }
        return nil
    }

    private func queryBootDiskBSDName() -> String? {
        let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["info", "-plist", "/"])
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["DeviceIdentifier"] as? String
    }

    private func isVolumeMounted(volumeName: String) -> Bool {
        let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["info", "/Volumes/\(volumeName)"])
        return result.exitCode == 0
    }

    private func collectDiskInfos() -> [DiskInfo] {
        // 仅对真正的「卷」（带 VolumeName 的条目）调用 diskutil info，
        // 避免对物理磁盘 / 容器本身逐个跑子进程，显著减少子进程数量。
        let volumes = enumerateVolumes()
        var infos: [DiskInfo] = []

        for (bsd, _) in volumes {
            guard let info = diskInfo(forBSDName: bsd) else { continue }
            guard let vname = info.volumeName, !vname.isEmpty else { continue }
            guard !info.isBootDisk else { continue }
            guard !info.isSystemVolume else { continue }
            guard info.sizeBytes > 1_000 else { continue }
            // 跳过没有文件系统的「容器」本身（如 Apple_APFS_Container）
            let fsLower = (info.fileSystem ?? "").lowercased()
            guard fsLower != "apple_apfs_container" && fsLower != "guid_partition_scheme" && fsLower != "fdisk_partition_scheme" else { continue }

            infos.append(info)
        }

        return infos
    }

    /// 从 `diskutil list -plist` 的 AllDisksAndPartitions 树中枚举所有「卷」（带 VolumeName 的条目）。
    /// 一次子进程即可拿到全部卷的设备名 + 卷名，无需逐个 diskutil info。
    private func enumerateVolumes() -> [(bsd: String, volumeName: String?)] {
        let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["list", "-plist"])
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }
        var out: [(String, String?)] = []
        func walk(_ entries: [[String: Any]]) {
            for entry in entries {
                if let vname = entry["VolumeName"] as? String, !vname.isEmpty,
                   let bsd = entry["DeviceIdentifier"] as? String {
                    out.append((bsd, vname))
                }
                if let parts = entry["Partitions"] as? [[String: Any]] {
                    walk(parts)
                }
                // APFS 容器内的卷通过嵌套的 APFSVolumes 数组呈现
                if let apfs = entry["APFSVolumes"] as? [[String: Any]] {
                    walk(apfs)
                }
            }
        }
        walk(allDisksAndPartitions)
        return out
    }

    private func diskInfo(forBSDName bsd: String) -> DiskInfo? {
        let result = ShellExecutor.run("/usr/sbin/diskutil", arguments: ["info", "-plist", bsd])
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let vname = plist["VolumeName"] as? String
        let size = (plist["Size"] as? Int64) ?? (plist["TotalSize"] as? Int64) ?? 0
        let mountPoint = plist["MountPoint"] as? String
        let isMounted = mountPoint != nil && !(mountPoint?.isEmpty ?? true)
        let fileSystem = plist["FilesystemTypeName"] as? String
            ?? plist["FilesystemName"] as? String
            ?? plist["Content"] as? String
        let bootBSD = self.bootDiskBSD
        let isBootDisk = bootBSD != nil && (bsd == bootBSD || (bootBSD ?? "").hasPrefix(bsd + "s"))

        return DiskInfo(
            id: bsd,
            bsdName: bsd,
            volumeName: vname,
            fileSystem: fileSystem,
            isMounted: isMounted,
            mountPoint: mountPoint,
            sizeBytes: size,
            isBootDisk: isBootDisk
        )
    }
}
