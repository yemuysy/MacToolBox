import Foundation

/// 启动项类型（照 KnockKnock 的 launchd 持久化分类）。
enum LaunchItemKind: String, CaseIterable, Sendable {
    case agent   // LaunchAgent：用户登录后运行，可显示 GUI
    case daemon  // LaunchDaemon：系统启动后运行，后台无 GUI

    var displayName: String { self == .agent ? "LaunchAgent" : "LaunchDaemon" }
    var icon: String { self == .agent ? "person.circle" : "gearshape" }
}

/// 启动项作用域（决定可管理性）。
enum LaunchItemScope: String, CaseIterable, Sendable {
    case user           // ~/Library/LaunchAgents — 当前用户可管理
    case system         // /Library/LaunchAgents|Daemons — 需管理员权限
    case systemReadOnly // /System/Library/... — 系统锁定，仅展示

    var displayName: String {
        switch self {
        case .user: return "用户级"
        case .system: return "系统级"
        case .systemReadOnly: return "系统锁定"
        }
    }
}

/// 启动项（LaunchAgent/LaunchDaemon）模型
struct LaunchItem: Identifiable, Equatable {
    let id: URL          // 原始 plist 文件 URL（激活态）或备份文件 URL（禁用态）
    let label: String
    let programArguments: [String]
    let runAtLoad: Bool
    let fileURL: URL
    let kind: LaunchItemKind
    let scope: LaunchItemScope
    /// 是否已被备份禁用（移入 Backup 目录）
    let disabled: Bool
    /// 是否可在 App 内直接管理（仅用户级可；系统级需管理员、系统锁定只读不可改）。
    var manageable: Bool { scope == .user }

    init(id: URL, label: String, programArguments: [String], runAtLoad: Bool, fileURL: URL,
         disabled: Bool, kind: LaunchItemKind = .agent, scope: LaunchItemScope = .user) {
        self.id = id
        self.label = label
        self.programArguments = programArguments
        self.runAtLoad = runAtLoad
        self.fileURL = fileURL
        self.kind = kind
        self.scope = scope
        self.disabled = disabled
    }
}

/// 启动项管理服务（照 KnockKnock 思路枚举多个持久化位置）。
///
/// 覆盖位置：
/// - 用户 LaunchAgents (`~/Library/LaunchAgents`)：可管理
/// - 系统 LaunchAgents (`/Library/LaunchAgents`)：需管理员
/// - 系统 LaunchDaemons (`/Library/LaunchDaemons`)：需管理员
/// - 系统只读 LaunchAgents/Daemons (`/System/Library/...`)：仅展示
///
/// 用户级以「备份禁用」方式管理（移动到 App 专属 Backup 目录即视为禁用，可一键恢复），
/// 不直接物理删除用户 plist。系统级项在 App 内不可改，提供 `launchctl` 命令供终端执行。
final class LaunchAgentService: ObservableObject, @unchecked Sendable {
    static let shared = LaunchAgentService()

    @Published private(set) var items: [LaunchItem] = []
    @Published private(set) var isBusy: Bool = false

    private let queue = DispatchQueue(label: "com.yemu.mactoolbox.launchagent", qos: .utility)
    private var started = false

    /// 用户级 LaunchAgents 目录
    private let agentsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }()

    /// 备份目录：~/Library/Application Support/MacToolBox/Backup/LaunchAgents
    private let backupDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacToolBox/Backup/LaunchAgents")
    }()

    private init() {}

    // MARK: - 启动（首次进入 Tab 时调用）

    func start() {
        guard !started else { return }
        started = true
        Logger.shared.info("LaunchAgentService starting")
        refresh()
    }

    // MARK: - 刷新

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let items = self.loadAll()
            DispatchQueue.main.async {
                self.items = items
            }
        }
    }

    // MARK: - 位置枚举（照 KnockKnock 的 launchd 持久化位置）

    private struct LaunchLocation {
        let dir: URL
        let kind: LaunchItemKind
        let scope: LaunchItemScope
    }

    private var locations: [LaunchLocation] {
        return [
            LaunchLocation(dir: agentsDir, kind: .agent, scope: .user),
            LaunchLocation(dir: URL(fileURLWithPath: "/Library/LaunchAgents"), kind: .agent, scope: .system),
            LaunchLocation(dir: URL(fileURLWithPath: "/Library/LaunchDaemons"), kind: .daemon, scope: .system),
            LaunchLocation(dir: URL(fileURLWithPath: "/System/Library/LaunchAgents"), kind: .agent, scope: .systemReadOnly),
            LaunchLocation(dir: URL(fileURLWithPath: "/System/Library/LaunchDaemons"), kind: .daemon, scope: .systemReadOnly),
        ]
    }

    // MARK: - 禁用 / 恢复（仅用户级）

    /// 备份禁用：将选中的 plist 移动到 Backup 目录（仅用户级可操作）。
    func disable(_ item: LaunchItem) {
        guard item.manageable, !item.disabled else { return }
        isBusy = true
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let dest = backupDir.appendingPathComponent(item.fileURL.lastPathComponent)
            do {
                try fm.moveItem(at: item.fileURL, to: dest)
            } catch {
                Logger.shared.info("LaunchAgent disable failed: \(error.localizedDescription)")
            }
            self.reload()
        }
    }

    /// 恢复：将 Backup 目录中的 plist 移回 LaunchAgents。
    func restore(fileName: String) {
        isBusy = true
        queue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let src = backupDir.appendingPathComponent(fileName)
            let dest = agentsDir.appendingPathComponent(fileName)
            do {
                try fm.moveItem(at: src, to: dest)
            } catch {
                Logger.shared.info("LaunchAgent restore failed: \(error.localizedDescription)")
            }
            self.reload()
        }
    }

    // MARK: - launchctl 命令（系统级项在 App 内不可改，提供命令供终端执行）

    /// 生成用于终端执行的 launchctl 命令（系统级自动加 sudo）。
    func launchctlCommand(for item: LaunchItem, action: String) -> String {
        let path = item.fileURL.path
        let sudo = item.scope == .system ? "sudo " : ""
        switch action {
        case "unload":
            return "\(sudo)launchctl unload -w \(path)"
        case "load":
            return "\(sudo)launchctl load -w \(path)"
        default:
            return "\(sudo)launchctl \(action) \(path)"
        }
    }

    // MARK: - 加载

    private func reload() {
        let items = loadAll()
        DispatchQueue.main.async { [weak self] in
            self?.items = items
            self?.isBusy = false
        }
    }

    /// 合并「激活态（各位置目录）」与「禁用态（仅用户级 Backup 目录）」。
    private func loadAll() -> [LaunchItem] {
        var result: [LaunchItem] = []
        for loc in locations {
            result += loadPlists(in: loc.dir, kind: loc.kind, scope: loc.scope, disabled: false)
        }
        result += loadPlists(in: backupDir, kind: .agent, scope: .user, disabled: true)
        return result.sorted {
            // 用户级在前，系统级、系统锁定在后；同级按 label 排序
            if $0.scope != $1.scope { return $0.scope.rawValue < $1.scope.rawValue }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private func loadPlists(in dir: URL, kind: LaunchItemKind, scope: LaunchItemScope, disabled: Bool) -> [LaunchItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "plist" }) else { return [] }
        return files.compactMap {
            LaunchAgentService.parsePlistFile($0, disabled: disabled, kind: kind, scope: scope)
        }
    }

    // MARK: - plist 解析

    /// 解析单个 launchd plist（供测试复用）。兼容旧签名（默认 agent/user）。
    static func parsePlistFile(_ file: URL, disabled: Bool) -> LaunchItem? {
        parsePlistFile(file, disabled: disabled, kind: .agent, scope: .user)
    }

    /// 解析单个 launchd plist，带类型与作用域上下文。
    static func parsePlistFile(_ file: URL, disabled: Bool, kind: LaunchItemKind, scope: LaunchItemScope) -> LaunchItem? {
        let fallback = LaunchItem(
            id: file,
            label: file.deletingPathExtension().lastPathComponent,
            programArguments: [],
            runAtLoad: false,
            fileURL: file,
            disabled: disabled,
            kind: kind,
            scope: scope
        )
        do {
            let data = try Data(contentsOf: file)
            guard let dict = try PropertyListSerialization.propertyList(
                from: data, format: nil
            ) as? [String: Any] else { return fallback }
            let label = (dict["Label"] as? String)
                ?? file.deletingPathExtension().lastPathComponent
            let args = (dict["ProgramArguments"] as? [String]) ?? []
            let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
            return LaunchItem(
                id: file,
                label: label,
                programArguments: args,
                runAtLoad: runAtLoad,
                fileURL: file,
                disabled: disabled,
                kind: kind,
                scope: scope
            )
        } catch {
            return fallback
        }
    }
}
