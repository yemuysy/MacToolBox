import FinderSync
import Foundation

/// MacToolBox Finder Sync 扩展主体（瘦扩展：仅渲染菜单 + 转发点击）。
/// 真正的文件操作全在主程序完成，本扩展通过 `RCMessager` 与主程序通信。
///
/// 配置来源（开源标准双机制）：
/// 1. App Group 共享容器内的 `menu.json`（主程序落盘）——`menu(for:)` 时直接读，Finder 重启也稳；
/// 2. 主程序推送的 `.menuConfig` 分布式通知——用于实时刷新。
///
/// 主线程单例式访问：FIFinderSync 实例由系统在主线程创建，`menu(for:)` 与 IPC 回调均在主线程，
/// 故可变状态无需额外隔离。类型声明为 `@unchecked Sendable` 仅为满足 Swift 6 下
/// `@Sendable` 闭包捕获 `self` 的约束。
/// `@objc(FinderSyncExt)` 固定 ObjC 运行时名为裸 `FinderSyncExt`，与 Info.plist 的
/// `NSExtensionPrincipalClass` 对齐。否则 Swift 默认名为 `模块名.类名`
/// （`FinderSyncExt.FinderSyncExt`），系统按裸名解析主类会失败，扩展无法实例化/注册。
@objc(FinderSyncExt)
final class FinderSyncExt: FIFinderSync, @unchecked Sendable {

    private var cachedMenuConfig: RCMenuConfig?
    private var heartbeatTimer: Timer?
    private var observer: NSObjectProtocol?

    override init() {
        super.init()
        // 全盘监听，让右键菜单出现在任意目录
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]

        observer = RCMessager.observe { [weak self] kind, payload in
            self?.handle(kind: kind, payload: payload)
        }
        // 主动要一次最新配置（主程序常驻，会立即回推），并直接从 App Group 文件读取兜底
        cachedMenuConfig = RCAppGroup.loadMenuConfig()
        RCMessager.post(kind: .requestConfig)
        startHeartbeat()
        rcLog("FinderSyncExt initialized")
    }

    deinit {
        if let o = observer { DistributedNotificationCenter.default().removeObserver(o) }
        heartbeatTimer?.invalidate()
    }

    // MARK: 消息处理（主线程）

    private func handle(kind: RCMessageKind, payload: String?) {
        switch kind {
        case .menuConfig:
            if let json = payload,
               let cfg = try? JSONDecoder().decode(RCMenuConfig.self, from: Data(json.utf8)) {
                cachedMenuConfig = cfg
                rcLog("menuConfig cached (enabled=\(cfg.enabled))")
            }
        case .running, .quit:
            break
        default:
            break
        }
    }

    // MARK: 心跳（10s 保活，触发主程序回推配置）

    private func startHeartbeat() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func sendHeartbeat() {
        RCMessager.post(kind: .heartbeat)
    }

    // MARK: 菜单构建

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // 优先用缓存，缓存为空时再尝试从 App Group 文件读取（Finder 重启兜底）
        var config = cachedMenuConfig ?? RCAppGroup.loadMenuConfig()
        guard let cfg = config, cfg.enabled else { return nil }

        let contextualKinds: [FIMenuKind] = [
            .contextualMenuForItems,
            .contextualMenuForContainer,
            .contextualMenuForSidebar,
            .toolbarItemMenu
        ]
        guard contextualKinds.contains(menuKind) else { return nil }

        let root = NSMenu(title: "MacToolBox")
        let top = NSMenuItem(title: "MacToolBox", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "MacToolBox")
        top.submenu = sub
        root.addItem(top)

        buildItems(into: sub, config: cfg)
        return root
    }

    private func buildItems(into menu: NSMenu, config: RCMenuConfig) {
        if config.showNewFile {
            let parent = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
            let m = NSMenu()
            for type in config.newFileTypes where !type.isEmpty {
                let item = NSMenuItem(title: "新建 \(type.uppercased())", action: #selector(handleAction(_:)), keyEquivalent: "")
                item.representedObject = ["action": "newFile", "sub": type]
                m.addItem(item)
            }
            if m.items.isEmpty {
                let none = NSMenuItem(title: "（未配置类型）", action: nil, keyEquivalent: "")
                none.isEnabled = false
                m.addItem(none)
            }
            parent.submenu = m
            menu.addItem(parent)
        }

        // 从模板新建（RightKit 标志性功能）
        if config.showNewFileFromTemplate, !config.templateFiles.isEmpty {
            let parent = NSMenuItem(title: "从模板新建", action: nil, keyEquivalent: "")
            let m = NSMenu()
            for name in config.templateFiles {
                let item = NSMenuItem(title: name, action: #selector(handleAction(_:)), keyEquivalent: "")
                item.representedObject = ["action": "newFileFromTemplate", "sub": name]
                m.addItem(item)
            }
            parent.submenu = m
            menu.addItem(parent)
        }

        if config.showCopyPath {
            addActionItem(menu, title: "复制路径", action: "copyPath")
        }

        if config.showCopyName {
            addActionItem(menu, title: "复制文件名", action: "copyName")
        }

        if config.showOpenWith, !config.openWithApps.isEmpty {
            let parent = NSMenuItem(title: "用 App 打开", action: nil, keyEquivalent: "")
            let m = NSMenu()
            for app in config.openWithApps {
                let item = NSMenuItem(title: app.name, action: #selector(handleAction(_:)), keyEquivalent: "")
                item.representedObject = ["action": "openWith", "sub": app.bundleID]
                m.addItem(item)
            }
            parent.submenu = m
            menu.addItem(parent)
        }

        if config.showOpenInTerminal {
            addActionItem(menu, title: "在终端打开", action: "openInTerminal")
        }

        if config.showRevealInFinder {
            addActionItem(menu, title: "在 Finder 中显示", action: "revealInFinder")
        }

        if config.showDelete {
            addActionItem(menu, title: "直接删除", action: "delete", danger: true)
        }

        if config.showToggleHidden {
            addActionItem(menu, title: "隐藏 / 显示", action: "toggleHidden")
        }

        if config.showCommonDirs, !config.commonDirs.isEmpty {
            let parent = NSMenuItem(title: "常用目录", action: nil, keyEquivalent: "")
            let m = NSMenu()
            for dir in config.commonDirs {
                let item = NSMenuItem(title: dir.name, action: #selector(handleAction(_:)), keyEquivalent: "")
                item.representedObject = ["action": "openCommonDir", "sub": dir.path]
                m.addItem(item)
            }
            parent.submenu = m
            menu.addItem(parent)
        }
    }

    private func addActionItem(_ menu: NSMenu, title: String, action: String, danger: Bool = false) {
        let item = NSMenuItem(title: title, action: #selector(handleAction(_:)), keyEquivalent: "")
        item.representedObject = ["action": action]
        if danger {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(item)
    }

    // MARK: 点击转发

    @objc private func handleAction(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: String],
              let action = dict["action"] else { return }
        let sub = dict["sub"]

        let controller = FIFinderSyncController.default()
        let targets = controller.selectedItemURLs() ?? []
        let targetedDir = controller.targetedURL()

        let payload = RCClickPayload(
            item: action,
            targets: targets.map { $0.absoluteString },
            targetedDir: targetedDir?.absoluteString,
            subItem: sub
        )
        if let json = payload.toJSON() {
            RCMessager.post(kind: .click, payload: json)
            rcLog("click forwarded: \(action)")
        }
    }
}
