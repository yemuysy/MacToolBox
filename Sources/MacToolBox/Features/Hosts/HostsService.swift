import Foundation

/// hosts 方案管理服务（参考 SwitchHosts）。
///
/// 职责：
/// - 管理多套 hosts 方案（增删改查、复制、导入/导出）
/// - 读取系统当前 /etc/hosts 内容
/// - 检测当前生效的方案（内容比对）
/// - 一键应用某方案：写入临时文件后经 `osascript ... with administrator privileges`
///   调起系统管理员密码框，将内容覆盖到 /etc/hosts（无需内置特权 Helper，兼容 ad-hoc 签名）
@MainActor
final class HostsService: ObservableObject {
    static let shared = HostsService()

    @Published private(set) var schemes: [HostScheme] = []
    @Published private(set) var systemHosts: String = ""
    @Published private(set) var activeSchemeID: String?
    @Published var lastMessage: (text: String, isError: Bool)?

    private let hostsPath = "/etc/hosts"

    private init() {
        start()
    }

    // MARK: - 加载

    /// 进入功能页时调用：载入已存方案 + 系统当前 hosts + 计算生效项
    func start() {
        schemes = ConfigStore.shared.hostSchemes()
        // 首次运行（且从未播种过示例）：给一个开发环境示例，避免空列表
        if schemes.isEmpty && !UserDefaults.standard.bool(forKey: "mactoolbox.hosts.seeded") {
            schemes = [HostScheme(name: "开发环境（示例）", content: sampleDevHosts)]
            persist()
            UserDefaults.standard.set(true, forKey: "mactoolbox.hosts.seeded")
        }
        refreshSystem()
    }

    /// 示例方案内容（首次运行播种用）
    private var sampleDevHosts: String {
        """
        # 开发环境 hosts 示例
        # 取消注释以启用本地域名映射
        # 127.0.0.1   localhost
        # 127.0.0.1   dev.api.example.com
        # 127.0.0.1   admin.example.com

        255.255.255.255 broadcasthost
        ::1             localhost
        """
    }

    /// 读取系统当前 /etc/hosts 并重新计算生效方案
    func refreshSystem() {
        systemHosts = readSystemHosts()
        recomputeActive()
    }

    private func readSystemHosts() -> String {
        (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
    }

    /// 内容比对，找出当前生效的方案
    private func recomputeActive() {
        let sys = normalize(systemHosts)
        activeSchemeID = schemes.first(where: { normalize($0.content) == sys })?.id
    }

    // MARK: - 方案 CRUD

    @discardableResult
    func createScheme(name: String = "新建方案") -> HostScheme {
        let scheme = HostScheme(name: name)
        schemes.append(scheme)
        persist()
        return scheme
    }

    func updateScheme(id: String, name: String? = nil, content: String? = nil) {
        guard let idx = schemes.firstIndex(where: { $0.id == id }) else { return }
        if let name = name { schemes[idx].name = name }
        if let content = content { schemes[idx].content = content }
        schemes[idx].updatedAt = Date()
        persist()
        if schemes[idx].id == activeSchemeID {
            // 编辑了生效中的方案：内容变了，重新判定（多半不再匹配系统）
            recomputeActive()
        }
    }

    func duplicateScheme(id: String) {
        guard let src = schemes.first(where: { $0.id == id }) else { return }
        let copy = src.duplicate()
        if let idx = schemes.firstIndex(where: { $0.id == id }) {
            schemes.insert(copy, at: idx + 1)
        } else {
            schemes.append(copy)
        }
        persist()
    }

    func deleteScheme(id: String) {
        schemes.removeAll { $0.id == id }
        if activeSchemeID == id { activeSchemeID = nil }
        persist()
    }

    func importFromFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastMessage = ("导入失败：无法读取文件", true)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let scheme = HostScheme(name: name, content: text)
        schemes.append(scheme)
        persist()
        lastMessage = ("已导入「\(name)」", false)
    }

    func exportScheme(_ scheme: HostScheme, to url: URL) {
        do {
            try scheme.content.write(to: url, atomically: true, encoding: .utf8)
            lastMessage = ("已导出「\(scheme.name)」", false)
        } catch {
            lastMessage = ("导出失败：\(error.localizedDescription)", true)
        }
    }

    // MARK: - 应用（写入系统 /etc/hosts）

    /// 将某方案内容写入 /etc/hosts，需要管理员授权
    func applyScheme(_ scheme: HostScheme) {
        guard !scheme.isSystem else {
            lastMessage = ("系统当前项为只读，无法应用", true)
            return
        }
        // 1. 写入临时文件（用户可写区域），避免 osascript 命令内转义 hosts 内容
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactoolbox-hosts-\(UUID().uuidString).hosts")
        do {
            try scheme.content.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            lastMessage = ("写入临时文件失败：\(error.localizedDescription)", true)
            return
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // 2. 经 osascript 调起管理员密码框，覆盖 /etc/hosts 并修复权限
        let src = tmpURL.path
        let applescript = "do shell script \"cp '\(escapeApplescript(src))' \(hostsPath) && chmod 644 \(hostsPath)\" with administrator privileges"
        let result = ShellExecutor.run("/usr/bin/osascript", arguments: ["-e", applescript])

        if result.exitCode == 0 {
            lastMessage = ("已切换到「\(scheme.name)」", false)
            refreshSystem()
        } else {
            let msg = result.stderr.isEmpty ? "已取消或失败" : result.stderr
            lastMessage = ("应用失败：\(msg)", true)
        }
    }

    // MARK: - 持久化

    private func persist() {
        ConfigStore.shared.setHostSchemes(schemes)
    }

    // MARK: - 工具

    /// 规范化：统一换行、去除首尾空白，用于内容比对
    private func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 转义 AppleScript 字符串中的单引号
    private func escapeApplescript(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
