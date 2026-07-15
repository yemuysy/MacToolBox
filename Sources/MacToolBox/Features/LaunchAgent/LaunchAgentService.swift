import Foundation

/// 启动项（LaunchAgent）模型
struct LaunchItem: Identifiable, Equatable {
    let id: URL          // 原始 plist 文件 URL（激活态）或备份文件 URL（禁用态）
    let label: String
    let programArguments: [String]
    let runAtLoad: Bool
    let fileURL: URL
    /// 是否已被备份禁用（移入 Backup 目录）
    let disabled: Bool
}

/// 启动项管理服务：读取 ~/Library/LaunchAgents 下的 plist，
/// 以「备份禁用」方式管理（移动到 App 专属 Backup 目录即视为禁用，可一键恢复），
/// 不直接物理删除用户 plist。
///
/// 该目录属于当前用户，普通权限即可读写，无需特权 Helper。
final class LaunchAgentService: ObservableObject, @unchecked Sendable {
    static let shared = LaunchAgentService()

    @Published private(set) var items: [LaunchItem] = []
    @Published private(set) var isBusy: Bool = false

    private let queue = DispatchQueue(label: "com.yemu.mactoolbox.launchagent", qos: .utility)
    private var started = false

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

    // MARK: - 禁用 / 恢复

    /// 备份禁用：将选中的 plist 移动到 Backup 目录。
    func disable(_ item: LaunchItem) {
        guard !item.disabled else { return }
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

    // MARK: - 加载

    private func reload() {
        let items = loadAll()
        DispatchQueue.main.async { [weak self] in
            self?.items = items
            self?.isBusy = false
        }
    }

    /// 合并「激活态（LaunchAgents 目录）」与「禁用态（Backup 目录）」。
    private func loadAll() -> [LaunchItem] {
        var result: [LaunchItem] = []
        result += loadPlists(in: agentsDir, disabled: false)
        result += loadPlists(in: backupDir, disabled: true)
        return result.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func loadPlists(in dir: URL, disabled: Bool) -> [LaunchItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "plist" }) else { return [] }

        return files.compactMap { LaunchAgentService.parsePlistFile($0, disabled: disabled) }
    }

    /// 解析单个 launchd plist 文件（internal，供测试复用）
    static func parsePlistFile(_ file: URL, disabled: Bool) -> LaunchItem? {
        let fallback = LaunchItem(
            id: file,
            label: file.deletingPathExtension().lastPathComponent,
            programArguments: [],
            runAtLoad: false,
            fileURL: file,
            disabled: disabled
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
                disabled: disabled
            )
        } catch {
            return fallback
        }
    }
}
