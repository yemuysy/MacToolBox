import Foundation

/// 一套 hosts 方案（参考 SwitchHosts 的 scheme 概念）。
/// 每套方案持有独立的 hosts 文本内容，可一键写入系统 /etc/hosts。
struct HostScheme: Codable, Identifiable, Equatable {
    /// 系统当前 /etc/hosts 的虚拟 id（只读，不可编辑/应用）
    static let systemID = "__system__"

    let id: String
    var name: String
    var content: String
    let createdAt: Date
    var updatedAt: Date

    /// 是否为系统当前项（展示用，不可编辑）
    var isSystem: Bool { id == HostScheme.systemID }

    init(id: String = UUID().uuidString, name: String, content: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 系统当前只读项
    static func system(content: String) -> HostScheme {
        HostScheme(id: HostScheme.systemID, name: "系统当前 (/etc/hosts)", content: content)
    }

    /// 复制为新方案（用于「复制」按钮）
    func duplicate() -> HostScheme {
        HostScheme(name: "\(name) 副本", content: content)
    }
}

enum HostsError: LocalizedError {
    case readFailed(Error)
    case writeFailed(String)
    case noAdmin

    var errorDescription: String? {
        switch self {
        case .readFailed(let e): return "读取 /etc/hosts 失败：\(e.localizedDescription)"
        case .writeFailed(let m): return "写入 /etc/hosts 失败：\(m)"
        case .noAdmin: return "需要管理员密码才能修改 /etc/hosts"
        }
    }
}
