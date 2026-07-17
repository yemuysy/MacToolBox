import SwiftUI
import AppKit

/// 应用启动时初始化主窗口 + 菜单栏 status item + 后台 service
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow!
    private var statusMenu: NSMenu!
    private var statusTitleCancellable: Any?
    private var preferencesWindow: NSWindow?

    /// 应用即将启动完成时设置激活策略，确保 Dock 图标可见
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.info("MacToolBox starting")

        // 1. 创建主窗口 + 菜单栏图标 + 功能面板
        setupMainWindow()
        setupMainMenu()
        setupStatusItem()
        setupPopover()
        startStatusTitleSubscription()

        // 2. 启动必需后台 service（菜单栏标题依赖）
        SystemInfoService.shared.start()

        // 3. 显示主窗口
        showMainWindow()

        // 4. 构建偏好设置窗口（隐藏，待打开）
        setupPreferencesWindow()

        // 5. 注册全局快捷键
        HotkeyService.shared.start()

        // 6. 若滚轮控制功能启用且已授权，拉起滚轮拦截
        if FeatureManager.shared.isEnabled(.scrollControl) {
            ScrollControlService.shared.startIfEnabled()
        }

        // 7. 右键增强：常驻监听扩展点击（无论功能是否启用，扩展仅在 config.enabled 时渲染菜单）
        RightClickService.shared.start()

        // 8. 注册系统服务（免费路线右键增强：零证书，出现在 Finder 右键「服务」子菜单）
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        Logger.shared.info("MacToolBox bootstrap complete, windows: \(NSApp.windows.count), app isActive: \(NSApp.isActive)")
    }

    /// Dock 图标被点击时重新显示主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTitleCancellable = nil
        SystemInfoService.shared.stop()
        ScrollControlService.shared.disableInterception()
        RightClickService.shared.stop()
        Logger.shared.info("MacToolBox terminating")
    }

    /// 关闭主窗口（红色 X）时不退出 App，仅隐藏
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - 主窗口

    private func setupMainWindow(initialFeature: FeatureID = .overview) {
        let host = NSHostingController(rootView: MenuBarRootView().selecting(initialFeature))
        let window = NSWindow(contentViewController: host)
        window.title = "MacToolBox"
        window.setContentSize(NSSize(width: 920, height: 660))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.center()
        self.mainWindow = window
        Logger.shared.info("Main window created, frame: \(window.frame)")
    }

    // MARK: - 主应用菜单

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单（MacToolBox）
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = NSMenu(title: "MacToolBox")
        appMenuItem.submenu?.addItem(NSMenuItem(title: "关于 MacToolBox",
                                                action: #selector(showAboutWindow(_:)),
                                                keyEquivalent: ""))
        appMenuItem.submenu?.addItem(.separator())
        let prefItem = NSMenuItem(title: "偏好设置…",
                                  action: #selector(openPreferencesFromMenu(_:)),
                                  keyEquivalent: ",")
        prefItem.target = self
        appMenuItem.submenu?.addItem(prefItem)
        appMenuItem.submenu?.addItem(.separator())
        appMenuItem.submenu?.addItem(NSMenuItem(title: "隐藏 MacToolBox",
                                                action: #selector(NSApplication.hide(_:)),
                                                keyEquivalent: "h"))
        appMenuItem.submenu?.addItem(NSMenuItem(title: "隐藏其他",
                                                action: #selector(NSApplication.hideOtherApplications(_:)),
                                                keyEquivalent: "h"))
        appMenuItem.submenu?.items.last?.keyEquivalentModifierMask = [.command, .option]
        appMenuItem.submenu?.addItem(NSMenuItem(title: "显示全部",
                                                action: #selector(NSApplication.unhideAllApplications(_:)),
                                                keyEquivalent: ""))
        appMenuItem.submenu?.addItem(.separator())
        appMenuItem.submenu?.addItem(NSMenuItem(title: "退出 MacToolBox",
                                                action: #selector(NSApplication.terminate(_:)),
                                                keyEquivalent: "q"))
        mainMenu.addItem(appMenuItem)

        // 文件菜单（含标准「关闭窗口」cmd+W，走系统 performClose，等同于点红色 X）
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = NSMenu(title: "文件")
        let closeItem = NSMenuItem(title: "关闭窗口",
                                   action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "w")
        fileMenuItem.submenu?.addItem(closeItem)
        mainMenu.addItem(fileMenuItem)

        // 编辑菜单（保留复制粘贴等标准操作）
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = NSMenu(title: "编辑")
        editMenuItem.submenu?.addItem(NSMenuItem(title: "撤销",
                                                 action: Selector(("undo:")),
                                                 keyEquivalent: "z"))
        editMenuItem.submenu?.addItem(NSMenuItem(title: "重做",
                                                 action: Selector(("redo:")),
                                                 keyEquivalent: "Z"))
        editMenuItem.submenu?.addItem(.separator())
        editMenuItem.submenu?.addItem(NSMenuItem(title: "剪切",
                                                 action: #selector(NSText.cut(_:)),
                                                 keyEquivalent: "x"))
        editMenuItem.submenu?.addItem(NSMenuItem(title: "拷贝",
                                                 action: #selector(NSText.copy(_:)),
                                                 keyEquivalent: "c"))
        editMenuItem.submenu?.addItem(NSMenuItem(title: "粘贴",
                                                 action: #selector(NSText.paste(_:)),
                                                 keyEquivalent: "v"))
        editMenuItem.submenu?.addItem(NSMenuItem(title: "全选",
                                                 action: #selector(NSText.selectAll(_:)),
                                                 keyEquivalent: "a"))
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAboutWindow(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// 显示主窗口（可选直接跳转到指定功能）
    func showMainWindow(reveal feature: FeatureID = .overview) {
        // 未启用且非核心功能：回退到着陆功能（核心功能 isEnabled 恒为 true）
        let target: FeatureID = FeatureManager.shared.isEnabled(feature) ? feature : .overview

        guard let window = mainWindow else { return }
        // 切换侧边栏到指定功能：通过重建 contentViewController 的根视图实现
        if let host = window.contentViewController as? NSHostingController<MenuBarRootView> {
            host.rootView = host.rootView.selecting(target)
        } else {
            setupMainWindow(initialFeature: target)
        }
        NSApp.setActivationPolicy(.regular)

        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Logger.shared.info("showMainWindow(reveal:\(target.rawValue)): isVisible=\(window.isVisible)")
    }

    /// 供菜单栏面板 / 快捷操作调用：跳转主窗口指定功能
    func reveal(feature: FeatureID) {
        showMainWindow(reveal: feature)
    }

    /// 切换主窗口显隐
    func toggleMainWindow() {
        guard let window = mainWindow else { return }
        if window.isVisible {
            hideMainWindow()
        } else {
            showMainWindow()
        }
    }

    /// 无参版本（供右键菜单 @objc 调用，等价跳转到概览）
    @objc func showMainWindow() {
        showMainWindow(reveal: .overview)
    }

    // MARK: - 菜单栏 status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // 加载自定义模板图标
            if let bundlePath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
               let image = NSImage(contentsOfFile: bundlePath) {
                image.isTemplate = false
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            } else {
                // 回退到 SF Symbol
                if let image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill",
                                        accessibilityDescription: "MacToolBox") {
                    image.isTemplate = true
                    button.image = image
                }
            }
            button.imagePosition = .imageLeft
            button.toolTip = "MacToolBox - 左键打开功能面板，右键菜单可显示主窗口 / 退出"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item

        // 右键菜单：显示主窗口 / 偏好设置 / 退出
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindowFromMenu(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let prefItem = NSMenuItem(title: "偏好设置…", action: #selector(openPreferencesFromMenu(_:)), keyEquivalent: ",")
        prefItem.target = self
        menu.addItem(prefItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 MacToolBox", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        self.statusMenu = menu

        Logger.shared.info("Status item registered, hasImage: \(item.button?.image != nil)")
    }

    // MARK: - 菜单栏实时标题

    /// 订阅 SystemInfoService 的 snapshot 发布，数据变化时自动刷新标题，避免独立 Timer
    private func startStatusTitleSubscription() {
        updateStatusTitle()
        statusTitleCancellable = SystemInfoService.shared.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
            }
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let cfg = ConfigStore.shared.menuBarConfig()

        // 总开关关闭：清空文字，仅保留图标
        guard cfg.showStats else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        let snap = SystemInfoService.shared.snapshot
        var parts: [String] = []
        if cfg.showCPU {
            parts.append("C\(String(format: "%.0f", snap.cpuUsage))")
        }
        if cfg.showMemory {
            parts.append("M\(String(format: "%.0f", snap.memoryUsage))")
        }
        if cfg.showNetwork {
            parts.append("↓\(formatRateShort(snap.networkDown))")
            parts.append("↑\(formatRateShort(snap.networkUp))")
        }
        if cfg.showTemperature {
            parts.append(snap.temperature.map { String(format: "%.0f°", $0) } ?? "—")
        }

        let text = parts.joined(separator: " ")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.animates = true
        // 菜单栏面板：只显示核心指标，剔除完整功能页
        let host = NSHostingController(rootView: MenuBarPanelView())
        popover.contentViewController = host
        self.popover = popover
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // 右键 / Option+点击：直接打开主窗口
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.option) ?? false)

        if isRightClick {
            if let button = statusItem.button {
                let point = NSPoint(x: 0, y: button.bounds.height + 4)
                statusMenu.popUp(positioning: nil, at: point, in: button)
            }
            return
        }

        // 左键：切换功能面板（含全部功能，无底部栏）
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    // MARK: - 右键菜单动作

    @objc private func showMainWindowFromMenu(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func openPreferencesFromMenu(_ sender: Any?) {
        openPreferences()
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 偏好设置窗口

    private func setupPreferencesWindow() {
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: SettingsView())
        )
        window.title = "MacToolBox 偏好设置"
        window.setContentSize(NSSize(width: 420, height: 460))
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 380, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        self.preferencesWindow = window
    }

    /// 打开（或前置）偏好设置窗口
    @objc func openPreferences() {
        guard let window = preferencesWindow else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Logger.shared.info("openPreferences: isVisible=\(window.isVisible)")
    }

    /// 仅隐藏主窗口，App 仍常驻，菜单栏图标保留；同时切换为无 Dock 的菜单栏模式
    @objc func hideMainWindow() {
        guard let window = mainWindow else { return }
        window.orderOut(nil)
        // 面板若已打开则一并关闭，避免只剩一个悬空面板
        if popover.isShown {
            popover.performClose(nil)
        }
        // 切换到菜单栏-only：Dock 图标消失，应用仍在后台运行
        NSApp.setActivationPolicy(.accessory)
        Logger.shared.info("hideMainWindow: isVisible=\(window.isVisible), policy=accessory")
    }

    // MARK: - 系统服务（免费路线右键增强，Finder 右键「服务」子菜单）

    /// NSServices 入口：由 Info.plist 的 `NSServices` 声明触发，`userData` 区分动作。
    /// 零证书，复用 `RightClickActionHandlers`。
    @objc func rightClickService(_ pboard: NSPasteboard, userData: String?, error: NSErrorPointer) {
        Task { @MainActor in
            // 从剪贴板读取选中的文件：优先 file URL，回退到路径字符串
            var urls: [URL] = []
            if let fileURLs = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                urls = fileURLs
            } else if let paths = pboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
                urls = paths.map { URL(fileURLWithPath: $0) }
            }
            guard let action = userData else {
                rcLog("RightClick(NSServices): missing userData")
                return
            }
            let cfg = ConfigStore.shared.rightClickConfig()
            guard cfg.enabled else {
                rcLog("RightClick(NSServices): feature disabled, skip")
                return
            }
            switch action {
            case "copyPath":
                if cfg.showCopyPath { RightClickActionHandlers.copyPaths(urls) }
            case "copyName":
                if cfg.showCopyName { RightClickActionHandlers.copyNames(urls) }
            case "newFile":
                if cfg.showNewFile { RightClickActionHandlers.createNewFile(type: cfg.newFileTypes.first, targets: urls, targetedDir: nil) }
            case "newFileFromTemplate":
                if cfg.showNewFileFromTemplate, let first = cfg.templateFiles.first {
                    RightClickActionHandlers.newFileFromTemplate(name: first, targets: urls, targetedDir: nil, templateFolder: cfg.templateFolder)
                }
            case "openWith":
                if cfg.showOpenWith, let first = cfg.openWithApps.first {
                    RightClickActionHandlers.openWith(bundleID: first.bundleID, targets: urls)
                }
            case "openInTerminal":
                if cfg.showOpenInTerminal { RightClickActionHandlers.openInTerminal(targets: urls, terminalBundleID: cfg.terminalBundleID) }
            case "revealInFinder":
                if cfg.showRevealInFinder { RightClickActionHandlers.revealInFinder(urls) }
            case "delete":
                if cfg.showDelete { RightClickActionHandlers.deleteDirectly(urls) }
            case "toggleHidden":
                if cfg.showToggleHidden { RightClickActionHandlers.toggleHidden(urls) }
            default:
                rcLog("RightClick(NSServices): unknown userData \(action)")
            }
        }
    }
}
