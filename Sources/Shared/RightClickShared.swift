import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import OSLog

// MARK: - 消息类型（主程序与扩展共用）

enum RCMessageKind: String, Codable, Sendable {
    case menuConfig     // 主 -> 扩展：菜单配置
    case running        // 主 -> 扩展：主程序已启动
    case quit           // 主 -> 扩展：主程序退出
    case click          // 扩展 -> 主：菜单点击
    case heartbeat      // 扩展 -> 主：心跳保活
    case requestConfig  // 扩展 -> 主：请求最新配置
}

/// 扩展侧渲染菜单所需的精简配置（由主程序 RightClickConfig 映射而来）
struct RCMenuConfig: Codable, Sendable {
    var enabled: Bool
    var showNewFile: Bool
    var showCopyPath: Bool
    var showOpenWith: Bool
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
    var item: String             // 动作 key: newFile/copyPath/openWith/delete/toggleHidden/openCommonDir
    var targets: [String]        // 选中项 file:// URL 字符串
    var targetedDir: String?     // 右键空白处所在目录的 file:// URL
    var subItem: String?         // 子项：新建文件类型 / App bundleID / 常用目录 path
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

// MARK: - 轻量日志（扩展与主程序共用）

private let rcLogHandle = OSLog(subsystem: "com.yemu.mactoolbox.rightclick", category: "ipc")

func rcLog(_ message: String) {
    os_log("%{public}@", log: rcLogHandle, type: .default, message)
}

// MARK: - IPC 信使（DistributedNotificationCenter + 签名校验）

/// 主程序与扩展通过 DistributedNotificationCenter 通信。
/// 所有消息带 SHA256(payload+secret) 签名，扩展与主程序内联同一份密钥，防止其它进程伪造点击注入。
struct RCMessager {
    static let name = "com.yemu.mactoolbox.rightclick"
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
