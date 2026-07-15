import Foundation
import IOKit

/// 通过 AppleSMC 读取 CPU 温度（°C）。
///
/// 实现移植自 Stats (exelban/stats) 已验证的 SMC 读取逻辑：
/// 精确对齐的 `SMCKeyData_t` 内存布局 + 两步读协议（data8=9 取键信息、data8=5 读字节，selector 恒为 2）。
/// 实测在 Apple Silicon（M4 Pro）上，普通用户进程即可读取真实温度键，无需 Stats 那套特权 helper。
///
/// 显示策略（对齐 Tencent Lemon / iStat 等常见做法）：
/// 取一组 CPU 核心 die 温度传感器（Tp*/Tc*/Te*/Tg*）的**平均值**，而非单个瞬时核心温度。
/// - 单个核心 die 在电源门控（idle 休眠）时会读出 ~5°C 的占位假值，全取平均会被拉低；
///   故过滤掉 <20°C 的异常值，只保留有效（活跃）核心求均值，平滑且贴近真实封装温度。
/// - 读不到时返回 nil，由 SystemInfoService 用时间滑动平均 + 保留旧值兜底，避免 UI 闪「—」。
final class SMCReader {
    private var conn: io_connect_t = 0
    private var isValid = false

    /// M4 Pro 实测有效的核心 die 温度键（覆盖 P 核 / E 核 / 能效区）。
    /// 这些是表示各核心/区域温度传感器的键；取其中有效者求平均即近似 Lemon 的 CPU 温度。
    private let coreTempKeys = [
        "Tp0D", "Tp05", "Tp01", "Tp09",
        "Tp0G", "Tp0H", "Tp0I", "Tp0K", "Tp0L", "Tp0M", "Tp0O", "Tp0P",
        "Tp0Q", "Tp0S", "Tp0T", "Tp0U",
        "Tp0o", "Tp0q", "Tp0t", "Tp0u", "Tp0v", "Tp0w",
        "Tc0D", "Tc0H",
        "Te01", "Te05", "Te0H", "Te0T",
        "Tg0D", "Tg0T"
    ]

    init?() {
        let matching = IOServiceMatching("AppleSMC")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == kIOReturnSuccess else { return nil }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return nil }
        let kr2 = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        guard kr2 == kIOReturnSuccess else { return nil }
        isValid = true
    }

    deinit {
        if isValid, conn != 0 {
            IOServiceClose(conn)
        }
    }

    /// 读取 CPU 温度（°C）：所有有效核心 die 温度的平均值。
    /// - 过滤 <20°C（电源门控占位假值）与 ≥110°C（异常）的读数；
    /// - 若无任何有效核心读出，重试整组最多 3 轮（规避冷启动偶发空读）；
    /// - 完全读不到返回 nil。
    func cpuTemperature() -> Double? {
        guard isValid else { return nil }

        for attempt in 0..<3 {
            var sum = 0.0
            var count = 0
            for key in coreTempKeys {
                if let t = getValue(key), t >= 20, t < 110 {
                    sum += t
                    count += 1
                }
            }
            if count > 0 {
                return sum / Double(count)
            }
            if attempt < 2 { usleep(50_000) } // 50ms 后重试
        }
        return nil
    }

    /// 读取「最热核心」温度（°C）：所有有效核心 die 温度的最大值。
    /// 同样过滤 <20°C（占位假值）与 ≥110°C（异常）。读不到返回 nil。
    func hottestCoreTemperature() -> Double? {
        guard isValid else { return nil }

        for attempt in 0..<3 {
            var maxT: Double = -Double.infinity
            var count = 0
            for key in coreTempKeys {
                if let t = getValue(key), t >= 20, t < 110 {
                    maxT = max(maxT, t)
                    count += 1
                }
            }
            if count > 0 {
                return maxT
            }
            if attempt < 2 { usleep(50_000) }
        }
        return nil
    }

    // MARK: - SMC 读取核心（对齐 Stats smc.swift）

    private func fourCharCode(_ s: String) -> UInt32 {
        var c: UInt32 = 0
        for ch in s.utf8 { c = (c << 8) | UInt32(ch) }
        return c
    }

    private func typeString(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        // SMC 类型码为 4 字节字符（如 "flt"、"sp78"），第 4 字节常为 0x00，本机实测为空格 0x20。
        // 只保留可见 ASCII（0x21...0x7E），排除空格与控制字符，
        // 否则 "flt "（带尾随空格）会导致 switch "flt" 匹配失败、温度读不到。
        return b.compactMap { (0x21...0x7E).contains($0) ? Character(UnicodeScalar($0)) : nil }
            .map(String.init)
            .joined()
    }

    private func bytesArray(_ t: SMCBytes_t) -> [UInt8] {
        [t.0,t.1,t.2,t.3,t.4,t.5,t.6,t.7,t.8,t.9,t.10,t.11,t.12,t.13,t.14,t.15,
         t.16,t.17,t.18,t.19,t.20,t.21,t.22,t.23,t.24,t.25,t.26,t.27,t.28,t.29,t.30,t.31]
    }

    private func call(_ index: UInt8, _ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
        let inSize = MemoryLayout<SMCKeyData_t>.stride
        var outSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inSize, &output, &outSize)
    }

    private func read(_ value: inout SMCVal_t) -> kern_return_t {
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = fourCharCode(value.key)
        input.data8 = 9 // kSMCGetKeyInfo
        var result = call(2, &input, &output)
        if result != kIOReturnSuccess { return result }

        value.dataSize = output.keyInfo.dataSize
        value.dataType = typeString(output.keyInfo.dataType)
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5 // kSMCReadBytes
        result = call(2, &input, &output)
        if result != kIOReturnSuccess { return result }

        value.bytes = bytesArray(output.bytes)
        return kIOReturnSuccess
    }

    private func getValue(_ key: String) -> Double? {
        var val = SMCVal_t(key: key)
        let result = read(&val)
        if result != kIOReturnSuccess { return nil }
        guard val.dataSize > 0 else { return nil }
        if val.bytes.allSatisfy({ $0 == 0 }) { return nil }
        let b = val.bytes
        switch val.dataType {
        case "flt":
            let u = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return Double(Float(bitPattern: u))
        case "sp78": return Double(Int(b[0]) * 256 + Int(b[1])) / 256.0
        case "sp87": return Double(Int(b[0]) * 256 + Int(b[1])) / 128.0
        case "sp96": return Double(Int(b[0]) * 256 + Int(b[1])) / 64.0
        case "sp69": return Double(Int(b[0]) * 256 + Int(b[1])) / 512.0
        case "sp5a": return Double(Int(b[0]) * 256 + Int(b[1])) / 1024.0
        case "sp4b": return Double(Int(b[0]) * 256 + Int(b[1])) / 2048.0
        case "sp3c": return Double(Int(b[0]) * 256 + Int(b[1])) / 4096.0
        case "sp1e": return Double(Int(b[0]) * 256 + Int(b[1])) / 16384.0
        case "spa5": return Double(Int(b[0]) * 256 + Int(b[1])) / 32.0
        case "spb4": return Double(Int(b[0]) * 256 + Int(b[1])) / 16.0
        case "spf0": return Double(Int(b[0]) * 256 + Int(b[1]))
        case "fpe2":
            let u = UInt16(b[0]) << 8 | UInt16(b[1])
            return Double(Int16(bitPattern: u)) / 4.0
        case "ui8":  return Double(b[0])
        case "ui16": return Double(Int(b[0]) * 256 + Int(b[1]))
        case "ui32": return Double(Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3]))
        default: return nil
        }
    }
}

// MARK: - SMC 数据结构（对齐 Apple SMC 私有接口 / Stats smc.swift）

private typealias SMCBytes_t = (
    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8
)

private struct SMCKeyData_t {
    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }
    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct keyInfo_t {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)
    init(key: String) { self.key = key }
}
