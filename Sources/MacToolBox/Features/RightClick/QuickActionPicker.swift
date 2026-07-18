import AppKit
import Foundation

/// Finder 快速操作（Quick Action）入口：接收文件 URL 后，在鼠标位置弹出动作选择器。
/// 由 `AppDelegate.application(_:openURLs:)` 在收到 `mactoolbox://pick?paths=...` 时调用。
///
/// 这是 ad-hoc 签名下也能稳定出现在 Finder 右键「快速操作」子菜单的免费路线，
/// 不依赖 NSServices（pbs 索引）也不依赖 Finder Sync 扩展（需付费证书）。
enum QuickActionPicker {

    /// 在鼠标当前位置弹出动作菜单。
    @MainActor
    static func present(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let cfg = ConfigStore.shared.rightClickConfig()
        guard cfg.enabled else {
            showTip("右键增强未启用，请在 MacToolBox 中开启")
            return
        }

        // 与 NSServices / Finder Sync 扩展一致的启用开关，顺序对应下方 items
        let showFlags = [
            cfg.showCopyPath,            // 复制路径
            cfg.showCopyName,           // 复制文件名
            cfg.showOpenInTerminal,     // 在终端打开
            cfg.showRevealInFinder,     // 在 Finder 中显示
            cfg.showNewFile,            // 新建文件
            cfg.showNewFileFromTemplate, // 从模板新建
            cfg.showOpenWith,           // 用 App 打开
            cfg.showToggleHidden,       // 隐藏 / 显示
            cfg.showDelete,             // 直接删除
        ]

        typealias Item = (title: String, icon: String, run: () -> Void)
        let items: [Item] = [
            ("复制路径", "doc.on.clipboard", { RightClickActionHandlers.copyPaths(urls) }),
            ("复制文件名", "character.textbox", { RightClickActionHandlers.copyNames(urls) }),
            ("在终端打开", "terminal.fill", { RightClickActionHandlers.openInTerminal(targets: urls, terminalBundleID: cfg.terminalBundleID) }),
            ("在 Finder 中显示", "eye.fill", { RightClickActionHandlers.revealInFinder(urls) }),
            ("新建文件", "doc.badge.plus", {
                RightClickActionHandlers.createNewFile(type: cfg.newFileTypes.first, targets: urls, targetedDir: nil)
            }),
            ("从模板新建", "doc.on.doc.fill", {
                RightClickActionHandlers.newFileFromTemplate(name: cfg.templateFiles.first, targets: urls, targetedDir: nil, templateFolder: cfg.templateFolder)
            }),
            ("用 App 打开", "app.fill", {
                if let app = cfg.openWithApps.first {
                    RightClickActionHandlers.openWith(bundleID: app.bundleID, targets: urls)
                }
            }),
            ("隐藏 / 显示", "eye.slash", { RightClickActionHandlers.toggleHidden(urls) }),
            ("直接删除", "trash", { RightClickActionHandlers.deleteDirectly(urls) }),
        ]

        let menu = NSMenu()
        menu.title = "MacToolBox"
        for (idx, it) in items.enumerated() {
            guard showFlags[idx] else { continue }
            // 依赖已配置项的动作，需确保有可用配置才显示
            if it.title == "从模板新建", cfg.templateFiles.isEmpty { continue }
            if it.title == "用 App 打开", cfg.openWithApps.isEmpty { continue }

            let mi = NSMenuItem(title: it.title,
                               action: #selector(QAPickerTarget.runItem(_:)),
                               keyEquivalent: "")
            mi.image = NSImage(systemSymbolName: it.icon, accessibilityDescription: nil)
            mi.representedObject = it.run
            mi.target = QAPickerTarget.shared
            menu.addItem(mi)
        }

        guard !menu.items.isEmpty else {
            showTip("没有可用的右键动作，请在 MacToolBox 中配置")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let loc = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: loc, in: nil)
    }

    @MainActor
    private static func showTip(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = "MacToolBox"
        alert.informativeText = msg
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// 承载菜单项点击：从 `representedObject` 取出闭包执行。
@MainActor
private final class QAPickerTarget: NSObject {
    static let shared = QAPickerTarget()
    @objc func runItem(_ sender: NSMenuItem) {
        if let block = sender.representedObject as? (() -> Void) {
            block()
        }
    }
}
