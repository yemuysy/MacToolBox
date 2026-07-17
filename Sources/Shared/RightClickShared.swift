import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import OSLog

// MARK: - 消息类型（主程序与扩展共用）

enum RCMessageKind: String, Codable, Sendable {
    case menuConfig     // 主 -> 扩展：菜单配置（实时刷新触发）
    case running        // 主 -> 扩展：主程序已启动
    case quit           // 主 -> 扩展：主程序退出
    case click          // 扩展 -> 主：菜单点击
    case heartbeat      // 扩展 -> 主：心跳保活
    case requestConfig  // 扩展 -> 主：请求最新配置
}

/// 扩展侧渲染菜单所需的精简配置（由主程序 RightClickConfig 映射而来）。
/// 该结构同时序列化为 App Group 共享容器内的 `menu.json`（开源项目 RightKit/SaneClick/Flicker
/// 的标准做法），扩展即使未收到通知也能直接读文件渲染菜单，Finder 重启后依然稳定。
struct RCMenuConfig: Codable, Sendable {
    var enabled: Bool
    var showNewFile: Bool
    var showNewFileFromTemplate: Bool
    var templateFolder: String?      // 模板目录路径（主程序读取，扩展不直访）
    var templateFiles: [String]      // 模板文件名列表（主程序枚举后下发，扩展仅展示）
    var showCopyPath: Bool
    var showCopyName: Bool
    var showOpenWith: Bool
    var showOpenInTerminal: Bool
    var terminalBundleID: String?
    var showRevealInFinder: Bool
    var showDelete: Bool
    var showToggleHidden: Bool
    var showCommonDirs: Bool
    var newFileTypes: [String]
    var openWithApps: [RCOpenWithApp]
    var commonDirs: [RCCommonDir]
}

struct RCOpenWithApp: Codable, Sendable, Identifiable {
    var id: String { bundleID }
    var name: String
    var bundleID: String
    var path: String
}

struct RCCommonDir: Codable, Sendable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
}

/// 扩展 -> 主 的点击负载
struct RCClickPayload: Codable, Sendable {
    var item: String             // 动作 key
    var targets: [String]        // 选中项 file:// URL 字符串
    var targetedDir: String?     // 右键空白处所在目录的 file:// URL
    var subItem: String?         // 子项：新建类型 / 模板文件名 / App bundleID / 常用目录 path
}

// MARK: - 编码辅助

protocol RCEncodable: Codable {
    func toJSON() -> String?
}

extension RCEncodable {
    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension RCMenuConfig: RCEncodable {}

extension RCClickPayload: RCEncodable {
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RCClickPayload.self, from: data) else { return nil }
        self = decoded
    }
}

// MARK: - App Group 共享容器（开源标准：配置落文件，扩展直接读）

/// 主程序（非沙盒）与 Finder Sync 扩展（沙盒）共享同一 App Group 容器。
/// 配置以 `menu.json` 落盘，扩展在 `menu(for:)` 时读取，无需等待通知。
enum RCAppGroup {
    static let id = "group.com.yemu.mactoolbox"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    static var menuJSONURL: URL? {
        containerURL?.appendingPathComponent("rightclick_menu.json")
    }

    /// 把菜单配置写入 App Group 共享文件（主程序侧调用）。
    static func saveMenuConfig(_ cfg: RCMenuConfig) -> Bool {
        guard let url = menuJSONURL else { return false }
        do {
            let data = try JSONEncoder().encode(cfg)
            try data.write(to: url, options: [.atomic])
            rcLog("RCAppGroup: menu.json written (\(data.count) bytes)")
            return true
        } catch {
            rcLog("RCAppGroup: write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 从 App Group 共享文件读取菜单配置（扩展侧调用，也用于主程序启动兜底）。
    static func loadMenuConfig() -> RCMenuConfig? {
        guard let url = menuJSONURL,
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(RCMenuConfig.self, from: data) else { return nil }
        return cfg
    }
}

// MARK: - 轻量日志（扩展与主程序共用）

private let rcLogHandle = OSLog(subsystem: "com.yemu.mactoolbox.rightclick", category: "ipc")

func rcLog(_ message: String) {
    os_log("%{public}@", log: rcLogHandle, type: .default, message)
}

// MARK: - IPC 信使（DistributedNotificationCenter + 签名校验）

/// 主程序与扩展通过 DistributedNotificationCenter 通信。
/// 所有消息带 SHA256(payload+secret) 签名，扩展与主程序内联同一份密钥，防止其它进程伪造点击注入。
///
/// 注意：沙盒扩展（Finder Sync）只能发送/接收 **以 App Group 为前缀** 的通知名，
/// 否则系统直接拦截 post。故通知名必须以 `group.com.yemu.mactoolbox.` 开头。
struct RCMessager {
    /// App Group（与主程序/扩展 entitlements 中的 `com.apple.security.application-groups` 一致）
    static let appGroup = "group.com.yemu.mactoolbox"
    static let name = "group.com.yemu.mactoolbox.rightclick"
    /// 主程序与扩展内联同一份密钥
    private static let secret = "MacToolBox-RClick-2026-shared-secret"

    static func sign(_ payload: String) -> String {
        let raw = payload + secret
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return String(raw.hashValue)
        #endif
    }

    static func verify(payload: String, signature: String) -> Bool {
        sign(payload) == signature
    }

    /// 发送一条消息（deliverImmediately 保证接收方繁忙时也能送达）
    static func post(kind: RCMessageKind, payload: String? = nil) {
        let p = payload ?? ""
        let info: [String: String] = [
            "kind": kind.rawValue,
            "payload": p,
            "signature": sign(p)
        ]
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }

    /// 注册监听，返回 observer token（需在 deinit / 停止时 removeObserver）
    @discardableResult
    static func observe(_ handler: @Sendable @escaping (RCMessageKind, String?) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { note in
            guard let info = note.userInfo as? [String: String],
                  let kindRaw = info["kind"],
                  let kind = RCMessageKind(rawValue: kindRaw),
                  let sig = info["signature"] else { return }
            let payload = info["payload"]
            guard verify(payload: payload ?? "", signature: sig) else {
                rcLog("RCMessager: dropped unsigned/invalid message \(kindRaw)")
                return
            }
            handler(kind, payload)
        }
    }
}

// MARK: - 弱引用盒子（用于把非 Sendable 实例安全塞进 @Sendable 闭包）

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var ref: T?
    init(_ ref: T) { self.ref = ref }
}
