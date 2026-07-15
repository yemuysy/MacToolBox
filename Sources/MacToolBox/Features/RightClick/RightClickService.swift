import AppKit
import Foundation

/// 右键增强的主程序侧服务：注册 IPC 监听、推送菜单配置、分派点击到动作执行器。
/// 常驻监听（无论功能是否启用），扩展只在 `config.enabled` 时渲染菜单。
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
        pushMenuConfig()
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
            pushMenuConfig()
        case .heartbeat:
            extensionAlive = true
            lastContact = Date()
        case .click:
            if let json = payload, let p = RCClickPayload(json: json) {
                lastContact = Date()
                extensionAlive = true
                RightClickActionHandlers.perform(p)
            }
        default:
            break
        }
    }

    // MARK: 配置推送

    func pushMenuConfig() {
        let menu = RCMenuConfig(from: config)
        if let json = menu.toJSON() {
            RCMessager.post(kind: .menuConfig, payload: json)
        }
    }

    // MARK: 配置变更入口（供 UI 调用）

    func setEnabled(_ on: Bool) {
        config.enabled = on
        persist()
        pushMenuConfig()
    }

    func update(_ mutate: (inout RightClickConfig) -> Void) {
        mutate(&config)
        persist()
        pushMenuConfig()
    }

    // MARK: 用 App 打开：管理 App 列表

    func addApp(_ url: URL) {
        guard let app = RightClickActionHandlers.makeApp(from: url),
              !config.openWithApps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        config.openWithApps.append(app)
        persist(); pushMenuConfig()
    }

    func removeApp(_ bundleID: String) {
        config.openWithApps.removeAll { $0.bundleID == bundleID }
        persist(); pushMenuConfig()
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
        persist(); pushMenuConfig()
    }

    // MARK: 常用目录

    func addCommonDir(_ url: URL) {
        let dir = RCCommonDir(name: url.lastPathComponent, path: url.absoluteString)
        guard !config.commonDirs.contains(where: { $0.path == dir.path }) else { return }
        config.commonDirs.append(dir)
        persist(); pushMenuConfig()
    }

    func removeCommonDir(_ path: String) {
        config.commonDirs.removeAll { $0.path == path }
        persist(); pushMenuConfig()
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
            showCopyPath: cfg.showCopyPath,
            showOpenWith: cfg.showOpenWith,
            showDelete: cfg.showDelete,
            showToggleHidden: cfg.showToggleHidden,
            showCommonDirs: cfg.showCommonDirs,
            newFileTypes: cfg.newFileTypes,
            openWithApps: cfg.openWithApps,
            commonDirs: cfg.commonDirs
        )
    }
}
