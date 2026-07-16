import AppKit

/// 贴图窗口：无边框、置顶、可拖移、滚轮缩放、Esc/X 关闭、支持多张叠加。
/// 借鉴 capcap 的 PinLauncher/PinWindow，去掉其内部依赖，保留核心交互。
final class PinWindow: NSWindow {
    var image: NSImage? {
        didSet { contentView?.needsLayout = true; contentView?.needsDisplay = true }
    }
    private var zoomScale: CGFloat = 1.0
    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 5.0

    override var canBecomeKey: Bool { true }

    convenience init(image: NSImage, origin: NSPoint) {
        let fitted = PinManager.fittedSize(for: image.size)
        self.init(
            contentRect: NSRect(origin: origin, size: fitted),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.image = image
        self.zoomScale = 1.0
        setup()
    }

    private func setup() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        let view = PinImageView(frame: NSRect(origin: .zero, size: frame.size))
        view.pinWindow = self
        contentView = view
    }

    func setZoom(_ scale: CGFloat) {
        let clamped = min(maxScale, max(minScale, scale))
        guard abs(clamped - zoomScale) > 0.001 else { return }
        zoomScale = clamped
        let newSize = NSSize(
            width: (image?.size.width ?? 0) * zoomScale,
            height: (image?.size.height ?? 0) * zoomScale
        )
        var f = frame
        // 以中心为锚点缩放
        let cx = f.midX, cy = f.midY
        f.size = newSize
        f.origin = NSPoint(x: cx - newSize.width / 2, y: cy - newSize.height / 2)
        setFrame(f, display: true, animate: false)
        (contentView as? PinImageView)?.relayout()
    }

    func zoomScaleValue() -> CGFloat { zoomScale }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 7:  // X
            close()
        case 53: // Esc
            close()
        default:
            super.keyDown(with: event)
        }
    }

    override func close() {
        orderOut(nil)
        contentView = nil
        PinManager.shared.remove(self)
    }
}

/// 贴图画布：绘制图片并响应拖移与滚轮缩放。
final class PinImageView: NSView {
    weak var pinWindow: PinWindow?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func relayout() {
        guard let win = pinWindow else { return }
        frame = NSRect(origin: .zero, size: win.frame.size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let win = pinWindow, let img = win.image else { return }
        let size = img.size
        let rect = NSRect(x: 0, y: 0, width: size.width * win.zoomScaleValue(),
                          height: size.height * win.zoomScaleValue())
        ctx.clear(bounds)
        img.draw(in: rect)
    }

    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let win = pinWindow else { return }
        var f = win.frame
        f.origin.x += event.deltaX
        f.origin.y += event.deltaY
        win.setFrameOrigin(f.origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard let win = pinWindow else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor = pow(1.05, -delta / 10)
        win.setZoom(win.zoomScaleValue() * factor)
    }
}

/// 管理所有贴图窗口（保持强引用，关闭时移除）。
@MainActor final class PinManager {
    static let shared = PinManager()
    private var windows: [PinWindow] = []

    /// 在当前光标所在屏幕居中贴一张图。
    func pin(_ image: NSImage) {
        let screen = activeScreen()
        let size = PinManager.fittedSize(for: image.size)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        let win = PinWindow(image: image, origin: origin)
        windows.append(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func add(_ w: PinWindow) { windows.append(w) }
    func remove(_ w: PinWindow) { windows.removeAll { $0 === w } }

    /// 从文件贴一张图（供「最近截图 → 贴图」使用）。
    func pin(url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        pin(img)
    }

    func closeAll() {
        for w in windows { w.close() }
        windows.removeAll()
    }

    static func fittedSize(for size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let maxW = max(200, vf.width - 80)
        let maxH = max(200, vf.height - 80)
        let ratio = min(1.0, min(maxW / size.width, maxH / size.height))
        return ratio >= 1 ? size : NSSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
    }

    private func activeScreen() -> NSScreen {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
