import Foundation

/// 特权操作协议：需要 root 权限的动作（如卸载系统级 LaunchAgent、清理系统目录）。
///
/// 设计意图：当前 MacToolBox 以普通权限运行，所有文件操作限定在用户可写区域（见 DiskCleaner 白名单）。
/// 需要更高权限的动作通过此协议抽象，未来接入 `SMAppService` + `NSXPCConnection` 的特权 Helper 时，
/// 只需提供 `PrivilegedOperations` 的另一个实现，调用方（DiskCleaner / LaunchAgentService）代码完全不变。
protocol PrivilegedOperations {
    /// Helper 是否已安装且可用
    var isAvailable: Bool { get }

    /// 删除文件（普通权限下仅能删除用户可写文件）
    func removeItem(at url: URL) -> Result<Void, Error>

    /// 移动 / 备份文件（普通权限下仅能操作用户可写区域）
    func moveItem(at src: URL, to dst: URL) -> Result<Void, Error>
}

/// 普通权限下的实现：仅处理用户可写区域，越权操作返回明确错误而非静默失败。
struct UserSpacePrivilegedOperations: PrivilegedOperations {
    let isAvailable = false

    func removeItem(at url: URL) -> Result<Void, Error> {
        do {
            try FileManager.default.removeItem(at: url)
            return .success(())
        } catch {
            return .failure(PrivilegedError.permissionDenied(url))
        }
    }

    func moveItem(at src: URL, to dst: URL) -> Result<Void, Error> {
        do {
            try FileManager.default.moveItem(at: src, to: dst)
            return .success(())
        } catch {
            return .failure(PrivilegedError.permissionDenied(src))
        }
    }
}

enum PrivilegedError: LocalizedError {
    case permissionDenied(URL)
    var errorDescription: String? {
        switch self {
        case .permissionDenied(let u):
            return "需要管理员权限才能操作：\(u.path)"
        }
    }
}

/// 全局特权操作入口（当前为普通权限实现，未来接 Helper 时替换此实例）
let privileged = UserSpacePrivilegedOperations()
