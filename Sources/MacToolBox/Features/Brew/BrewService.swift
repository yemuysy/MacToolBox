import Foundation

/// Homebrew 操作服务
///
/// 封装常用 brew 子命令，所有耗时操作在后台线程执行，
/// 通过 @Published 暴露列表/状态/输出，UI 直接绑定。
final class BrewService: ObservableObject, @unchecked Sendable {
    static let shared = BrewService()

    // MARK: - 概览

    struct Overview: Equatable {
        var brewVersion: String = "—"
        var homebrewPath: String = "—"
        var outdatedCount: Int = 0
        var cleanableBytes: Int64 = 0
    }

    // MARK: - 模型

    struct PkgInfo: Identifiable, Equatable {
        let id: String          // 名称
        let name: String
        let version: String
        let isCask: Bool
        /// 是否为叶子节点（无其他已安装包依赖它，可安全卸载）
        let isLeaf: Bool
    }

    struct OutdatedInfo: Identifiable, Equatable {
        let id: String
        let name: String
        let current: String
        let latest: String
        let isCask: Bool
    }

    // MARK: - 状态

    @Published private(set) var overview = Overview()
    @Published private(set) var formulas: [PkgInfo] = []
    @Published private(set) var casks: [PkgInfo] = []
    @Published private(set) var outdated: [OutdatedInfo] = []
    @Published private(set) var isBusy: Bool = false
    /// 最近一次命令的尾部输出（用于 UI 展示进度/结果）
    @Published private(set) var lastOutput: String = ""
    @Published private(set) var lastError: Bool = false
    /// 当前正在执行的命令描述
    @Published private(set) var runningTask: String = ""

    private let queue = DispatchQueue(label: "com.yemu.mactoolbox.brew", qos: .utility)
    private var isStarted = false

    private init() {}

    // MARK: - 启动（首次进入 Tab 时调用）

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Logger.shared.info("BrewService starting")
        refreshAll()
    }

    // MARK: - 一键刷新全部

    func refreshAll() {
        queue.async { [weak self] in
            self?.loadOverview()
            self?.loadInstalled()
            self?.loadOutdated()
        }
    }

    // MARK: - 概览数据

    /// 加载概览。
    /// - `includeCleanable`：是否执行 `brew cleanup -n --prune=all` 干跑以估算可清理空间。
    ///   该命令较耗时（遍历所有瓶身），仅在「全部刷新」时执行；常规动作后的局部刷新跳过它，
    ///   复用上次缓存的可清理字节数，避免每次操作后都跑一遍慢命令。
    private func loadOverview(includeCleanable: Bool = true) {
        let brewVer = run("\(brewPath) --version").out
            .split(whereSeparator: \.isNewline)
            .first?
            .replacingOccurrences(of: "Homebrew ", with: "")
            .trimmingCharacters(in: .whitespaces) ?? "—"

        let path = run("\(brewPath) --prefix").out.trimmingCharacters(in: .whitespacesAndNewlines)
        let homePath = path.isEmpty ? "—" : path

        let fOut = run("\(brewPath) outdated --formula").out
        let cOut = run("\(brewPath) outdated --cask").out
        let outdatedCount = (fOut + cOut)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count

        // 干跑清理，解析可清理空间（最后一行形如 "Would remove ... (212.5MB)"）
        // 仅当显式要求时执行，避免每次动作后都跑慢命令。
        let cleanable: Int64 = includeCleanable
            ? parseCleanableBytes(run("\(brewPath) cleanup -n --prune=all").out)
            : overview.cleanableBytes

        DispatchQueue.main.async { [weak self] in
            self?.overview = Overview(
                brewVersion: brewVer.isEmpty ? "—" : brewVer,
                homebrewPath: homePath,
                outdatedCount: outdatedCount,
                cleanableBytes: cleanable
            )
        }
    }

    private func parseCleanableBytes(_ text: String) -> Int64 {
        // 优先解析汇总行："This operation would free approximately 2.6GB of disk space."
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            if let range = s.range(of: "would free approximately") {
                let tail = String(s[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ")
                    .first ?? ""
                let bytes = parseByteSize(tail)
                if bytes > 0 { return bytes }
            }
        }
        return 0
    }

    // MARK: - 已安装列表

    private func loadInstalled() {
        let fOut = run("\(brewPath) list --formula").out
        let cOut = run("\(brewPath) list --cask").out
        // 叶子节点（无人依赖），去掉 cask 提示行
        let leavesOut = run("\(brewPath) leaves").out
        let leaves = Set(leavesOut.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning") })

        let fs = parseInstalled(fOut, isCask: false, leaves: leaves)
        let cs = parseInstalled(cOut, isCask: true, leaves: leaves)

        DispatchQueue.main.async { [weak self] in
            self?.formulas = fs
            self?.casks = cs
        }
    }

    private func parseInstalled(_ text: String, isCask: Bool, leaves: Set<String>) -> [PkgInfo] {
        var result: [PkgInfo] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let name: String
            let version: String
            if let vRange = line.range(of: " "),
               !line.hasPrefix(" ") {
                name = String(line[..<vRange.lowerBound])
                version = String(line[vRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                name = line
                version = ""
            }
            result.append(PkgInfo(
                id: name, name: name, version: version,
                isCask: isCask, isLeaf: leaves.contains(name)
            ))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - 可更新列表

    private func loadOutdated() {
        // 分别获取 formula 和 cask 可更新列表（--formula 和 --cask 不能同时用）
        let fOut = run("\(brewPath) outdated --formula --verbose").out
        let cOut = run("\(brewPath) outdated --cask --verbose").out

        var result: [OutdatedInfo] = []
        result.append(contentsOf: parseOutdated(fOut, isCask: false))
        result.append(contentsOf: parseOutdated(cOut, isCask: true))
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        DispatchQueue.main.async { [weak self] in
            self?.outdated = result
            self?.overview.outdatedCount = result.count
        }
    }

    private func parseOutdated(_ text: String, isCask: Bool) -> [OutdatedInfo] {
        var result: [OutdatedInfo] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // 跳过可能的 help/usage 行
            guard !line.hasPrefix("Usage:") && !line.hasPrefix("List ") && !line.hasPrefix(" -") && !line.hasPrefix("  ") && !line.contains("brew outdated") else { continue }
            // formula: "ada-url (3.4.3) < 3.4.4"
            // cask:    "google-chrome (145.0.7632.117) != 150.0.7871.115"
            guard let open = line.range(of: " ("),
                  let close = line.range(of: ")", range: open.upperBound..<line.endIndex),
                  let sep = line.range(of: isCask ? " != " : " < ", range: close.upperBound..<line.endIndex) else { continue }
            let name = String(line[..<open.lowerBound])
            let current = String(line[open.upperBound..<close.lowerBound])
            let latest = String(line[sep.upperBound...])
            result.append(OutdatedInfo(id: name, name: name, current: current, latest: latest, isCask: isCask))
        }
        return result
    }

    // MARK: - 动作

    func runUpdate() {
        execute("\(brewPath) update", taskLabel: "更新 Homebrew")
    }

    func runUpgradeAll() {
        execute("\(brewPath) upgrade", taskLabel: "升级全部包")
    }

    func runUpgrade(name: String) {
        execute("\(brewPath) upgrade \(name)", taskLabel: "升级 \(name)")
    }

    func runCleanup() {
        execute("\(brewPath) cleanup --prune=all", taskLabel: "清理旧版本")
    }

    func runUninstall(name: String, isCask: Bool) {
        let kind = isCask ? "--cask" : "--formula"
        execute("\(brewPath) uninstall \(kind) \(name)", taskLabel: "卸载 \(name)")
    }

    func runAutoremove() {
        execute("\(brewPath) autoremove", taskLabel: "清理孤儿依赖")
    }

    /// 安装新包。先尝试 formula，失败（cask-only 包）回退 cask。
    /// 返回是否成功启动；UI 在 lastOutput 里看结果。
    func runInstall(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        execute("\(brewPath) install \(trimmed)", taskLabel: "安装 \(trimmed)")
    }

    /// 查询某包被多少个已安装包依赖（用于卸载风险提示）。
    /// 返回依赖者数量；叶子节点返回 0。
    func dependentCount(name: String, completion: @escaping @Sendable (Int) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let out = self.run("\(self.brewPath) uses --installed \(name)").out
            let count = out.split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("Warning") && !$0.hasPrefix("Usage") }
                .count
            DispatchQueue.main.async { completion(count) }
        }
    }

    // MARK: - 命令执行核心

    private func execute(_ command: String, taskLabel: String) {
        guard !isBusy else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isBusy = true
            self?.runningTask = taskLabel
            self?.lastOutput = "执行中：\(command)\n"
            self?.lastError = false
        }
        queue.async { [weak self] in
            let res = self?.run(command) ?? (out: "", code: 1)
            let tail = res.out.split(whereSeparator: \.isNewline).suffix(12)
                .joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastOutput = "\(command)\n\n\(tail)"
                self.lastError = res.code != 0
                self.isBusy = false
                self.runningTask = ""
                // 动作完成后刷新所有数据（跳过耗时的 cleanup 干跑，复用上次估算）
                self.loadOverview(includeCleanable: false)
                self.loadInstalled()
                self.loadOutdated()
            }
        }
    }

    // MARK: - 命令运行（同步，后台线程调用）

    private func run(_ command: String) -> (out: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (out: "启动失败：\(error.localizedDescription)", code: 1)
        }
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        let combined = out.isEmpty ? err : out + (err.isEmpty ? "" : "\n" + err)
        return (out: combined, code: process.terminationStatus)
    }

    // MARK: - 路径

    private let brewPath = "/opt/homebrew/bin/brew"
}
