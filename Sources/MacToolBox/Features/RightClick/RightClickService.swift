import AppKit
import Foundation

/// 右键增强的主程序侧服务：注册 IPC 监听、发布菜单配置（通知 + App Group 共享文件）、分派点击到动作执行器。
/// 常驻监听（无论功能是否启用），扩展只在 `config.enabled` 时渲染菜单。
///
/// 发布机制对标开源（RightKit / SaneClick / Flicker）：每次配置变更都把 `RCMenuConfig`
/// 写入 App Group 共享容器的 `menu.json`，扩展直接读文件渲染，Finder 重启后依然稳定；
/// 同时保留分布式通知做实时刷新触发。
@MainActor
final class RightClickService: ObservableObject {
    static let shared = RightClickService()

    @Published var config: RightClickConfig
    @Published private(set) var extensionAlive = false
    @Published private(set) var lastContact: Date?

    private var observer: NSObjectProtocol?
    private var livenessTimer: Timer?

    private init() {
        config = ConfigStore.shared.rightClickConfig()
    }

    // MARK: 生命周期

    func start() {
        guard observer == nil else { return }
        let box = WeakBox(self)
        observer = RCMessager.observe { kind, payload in
            Task { @MainActor in box.ref?.handle(kind: kind, payload: payload) }
        }
        publishMenuConfig()          // 写 App Group 文件 + 推通知（开源双机制）
        RCMessager.post(kind: .running)
        startLivenessWatch()
        rcLog("RightClickService started")
    }

    func stop() {
        if let o = observer { DistributedNotificationCenter.default().removeObserver(o) }
        observer = nil
        livenessTimer?.invalidate()
        livenessTimer = nil
        RCMessager.post(kind: .quit)
    }

    private func startLivenessWatch() {
        livenessTimer?.invalidate()
        let box = WeakBox(self)
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                guard let self = box.ref else { return }
                if let last = self.lastContact, Date().timeIntervalSince(last) > 30 {
                    self.extensionAlive = false
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    // MARK: 消息

    private func handle(kind: RCMessageKind, payload: String?) {
        switch kind {
        case .requestConfig:
            publishMenuConfig()
        case .heartbeat:
            extensionAlive = true
            lastContact = Date()
        case .click:
            if let json = payload, let p = RCClickPayload(json: json) {
                lastContact = Date()
                extensionAlive = true
                RightClickActionHandlers.perform(p, config: config)
            }
        default:
            break
        }
    }

    // MARK: 配置发布（通知 + App Group 共享文件）

    /// 生成菜单配置并同时：①写入 App Group 共享文件 ②推通知刷新。扩展两条路径都能拿到最新配置。
    func publishMenuConfig() {
        let menu = RCMenuConfig(from: config)
        _ = RCAppGroup.saveMenuConfig(menu)     // 开源机制：落文件，扩展直接读
        if let json = menu.toJSON() {
            RCMessager.post(kind: .menuConfig, payload: json)
        }
    }

    // MARK: 配置变更入口（供 UI 调用）

    func setEnabled(_ on: Bool) {
        config.enabled = on
        persist()
        publishMenuConfig()
    }

    func update(_ mutate: (inout RightClickConfig) -> Void) {
        mutate(&config)
        persist()
        publishMenuConfig()
    }

    // MARK: 用 App 打开：管理 App 列表

    func addApp(_ url: URL) {
        guard let app = RightClickActionHandlers.makeApp(from: url),
              !config.openWithApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        config.openWithApps.append(app)
        persist(); publishMenuConfig()
    }

    func removeApp(_ bundleID: String) {
        config.openWithApps.removeAll { $0.bundleID == bundleID }
        persist(); publishMenuConfig()
    }

    /// 扫描常用编辑器，把本机存在的加入列表（去重）
    func scanDefaultApps() {
        let ids = [
            "com.apple.TextEdit",
            "com.microsoft.VSCode",
            "com.sublimetext.4",
            "com.sublimetext.3",
            "com.macromates.TextMate",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.todesktop.230313mzl4w4u92" // Cursor
        ]
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               let app = RightClickActionHandlers.makeApp(from: url),
               !config.openWithApps.contains(where: { $0.bundleID == app.bundleID }) {
                config.openWithApps.append(app)
            }
        }
        persist(); publishMenuConfig()
    }

    // MARK: 终端 App

    func setTerminal(_ url: URL?) {
        if let url, let app = RightClickActionHandlers.makeApp(from: url) {
            config.terminalBundleID = app.bundleID
        } else {
            config.terminalBundleID = nil
        }
        persist(); publishMenuConfig()
    }

    func scanDefaultTerminal() {
        let ids = ["com.googlecode.iterm2", "com.apple.Terminal", "com.todesktop.230313mzl4w4u92"]
        for id in ids {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
                config.terminalBundleID = id
                persist(); publishMenuConfig()
                return
            }
        }
    }

    func terminalName() -> String {
        guard let id = config.terminalBundleID else { return "终端" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           let app = RightClickActionHandlers.makeApp(from: url) {
            return app.name
        }
        return "终端"
    }

    // MARK: 模板目录

    func setTemplateFolder(_ url: URL?) {
        guard let url else { return }
        config.templateFolder = url.path
        refreshTemplateFiles()
        persist(); publishMenuConfig()
    }

    /// 枚举模板目录下的文件（主程序直访，扩展不碰沙盒外目录）
    private func refreshTemplateFiles() {
        guard let folder = config.templateFolder else {
            config.templateFiles = []
            return
        }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: folder) else {
            config.templateFiles = []
            return
        }
        config.templateFiles = contents.filter { name in
            let full = (folder as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            return !isDir.boolValue && !name.hasPrefix(".")
        }.sorted()
    }

    // MARK: 常用目录

    func addCommonDir(_ url: URL) {
        let dir = RCCommonDir(name: url.lastPathComponent, path: url.absoluteString)
        guard !config.commonDirs.contains(where: { $0.path == dir.path }) else { return }
        config.commonDirs.append(dir)
        persist(); publishMenuConfig()
    }

    func removeCommonDir(_ path: String) {
        config.commonDirs.removeAll { $0.path == path }
        persist(); publishMenuConfig()
    }

    private func persist() {
        ConfigStore.shared.setRightClickConfig(config)
    }
}

// MARK: - RCMenuConfig 由 RightClickConfig 映射

extension RCMenuConfig {
    init(from cfg: RightClickConfig) {
        self.init(
            enabled: cfg.enabled,
            showNewFile: cfg.showNewFile,
            showNewFileFromTemplate: cfg.showNewFileFromTemplate,
            templateFolder: cfg.templateFolder,
            templateFiles: cfg.templateFiles,
            showCopyPath: cfg.showCopyPath,
            showCopyName: cfg.showCopyName,
            showOpenWith: cfg.showOpenWith,
            showOpenInTerminal: cfg.showOpenInTerminal,
            terminalBundleID: cfg.terminalBundleID,
            showRevealInFinder: cfg.showRevealInFinder,
            showDelete: cfg.showDelete,
            showToggleHidden: cfg.showToggleHidden,
            showCommonDirs: cfg.showCommonDirs,
            newFileTypes: cfg.newFileTypes,
            openWithApps: cfg.openWithApps,
            commonDirs: cfg.commonDirs
        )
    }
}
