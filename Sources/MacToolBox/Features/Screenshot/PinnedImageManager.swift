import AppKit
import Foundation

/// 悬浮「贴图」窗口管理器（@MainActor 单例）。
///
/// 把截图以**无边框、置顶、可拖拽、可关闭**的浮动窗口钉在屏幕上，
/// 用法类似 Snipaste 的「贴图」：截图后直接钉在屏幕上做参照/对照，
/// 不影响其它操作，Esc 或右键「关闭贴图」即可收起。
///
/// 设计：纯 AppKit（`NSWindow` / `NSImageView`），由 @MainActor 单例统一管理，
/// 所有窗口实例存活在主线程，不阻塞 SwiftUI 主线程。
@MainActor
final class PinnedImageManager: @unchecked Sendable {
    static let shared = PinnedImageManager()

    private var windows: [PinnedWindow] = []

    /// 从文件 URL 贴图（如刚保存的截图）。
    func pin(url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        pin(img)
    }

    /// 从内存图片贴图。
    func pin(_ image: NSImage) {
        let w = PinnedWindow(image: image)
        w.onClose = { [weak self] in
            self?.windows.removeAll { $0 === w }
        }
        w.show()
        windows.append(w)
    }

    /// 关闭所有贴图窗口。
    func closeAll() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }
}

/// 单个贴图窗口的承载。NSObject 以便充当 `NSWindowDelegate`，
/// 在窗口关闭时回调 `onClose` 让管理器释放引用。
/// 整体标记 @MainActor：其调用的 NSWindow/NSApp API 均属主线程。
@MainActor
final class PinnedWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    init(image: NSImage) {
        // 显示尺寸：保留原始比例，最长边不超过主屏可见区的 70%。
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxSide = visible.width * 0.7
        let src = image.size
        var w = src.width, h = src.height
        let longest = max(w, h)
        if longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            w *= scale; h *= scale
        }
        w = max(80, w); h = max(60, h)

        let panel = PinnedPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let iv = DraggableImageView(image: image)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.frame = NSRect(x: 0, y: 0, width: w, height: h)
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.separatorColor.cgColor
        iv.layer?.shadowOpacity = 0.25
        iv.layer?.shadowRadius = 8
        panel.contentView = iv

        // 右键菜单：关闭贴图
        let menu = NSMenu()
        let closeItem = NSMenuItem(title: "关闭贴图", action: #selector(closeMenu(_:)), keyEquivalent: "")
        menu.addItem(closeItem)
        iv.menu = menu

        window = panel
        super.init()
        panel.delegate = self
        closeItem.target = self
    }

    @objc private func closeMenu(_ sender: Any) {
        close()
    }

    /// 居中显示并置顶。
    func show() {
        if let screen = NSScreen.main {
            var r = window.frame
            r.origin = NSPoint(
                x: screen.visibleFrame.midX - r.width / 2,
                y: screen.visibleFrame.midY - r.height / 2
            )
            window.setFrame(r, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// 无边框可置顶面板：允许成为 key 窗口以接收 Esc 关闭。
final class PinnedPanel: NSWindow {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc 关闭贴图
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// 可拖拽的 NSImageView：按下并拖动即移动所属窗口，实现「贴图」自由摆放。
final class DraggableImageView: NSImageView {
    private var dragOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let win = window else { return }
        var newOrigin = win.frame.origin
        newOrigin.x += event.locationInWindow.x - origin.x
        newOrigin.y += event.locationInWindow.y - origin.y
        win.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }
}
