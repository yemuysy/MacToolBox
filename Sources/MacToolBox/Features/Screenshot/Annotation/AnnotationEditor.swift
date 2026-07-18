import AppKit

// MARK: - 标注编辑器：全屏/大窗口，截图图片背景 + 画布 + 底部工具栏。

final class AnnotationEditorWindow: NSWindow {

    // MARK: - 回调

    /// 用户点击「完成」→ 输出合并后的图片（原图 + 所有标注）。
    var onDone: ((NSImage) -> Void)?

    /// 用户取消 → 不输出任何东西。
    var onCancel: (() -> Void)?

    // MARK: - 内部组件

    private let canvas = AnnotationCanvas()
    private let annoToolbar = AnnotationToolbar()

    // MARK: - 初始化

    /// - Parameter image: 截图图片
    /// - Parameter screenRect: 若提供，则为全局屏幕坐标的选区矩形，编辑器将「就地」覆盖在该区域（1:1 比例）；
    ///                         nil 时退化为居中缩放窗口。
    convenience init(image: NSImage, screenRect: NSRect? = nil) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame

        let scale: CGFloat
        let displaySize: NSSize
        let origin: NSPoint
        let inPlace: Bool

        if let sr = screenRect {
            scale = 1.0
            displaySize = NSSize(width: max(sr.width, 1), height: max(sr.height, 1))
            origin = sr.origin
            inPlace = true
        } else {
            let barHeight: CGFloat = 52
            let maxW = vf.width - 80
            let maxH = vf.height - 160 // 预留顶部+工具栏空间
            let imgSize = image.size
            let ratioW = maxW / imgSize.width
            let ratioH = maxH / imgSize.height
            scale = min(ratioW, ratioH, 1.0) // 不放大
            displaySize = NSSize(
                width: floor(imgSize.width * scale),
                height: floor(imgSize.height * scale) + barHeight + 8
            )
            origin = NSPoint(
                x: vf.midX - displaySize.width / 2,
                y: vf.midY - displaySize.height / 2
            )
            inPlace = false
        }

        self.init(
            contentRect: NSRect(origin: origin, size: displaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setup(image: image, scale: scale, inPlace: inPlace)
    }

    private func setup(image: NSImage, scale: CGFloat, inPlace: Bool) {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        // 容器视图
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        contentView = container

        // 画布铺满整个窗口（就地模式下图片 1:1 恰好覆盖原选区）
        canvas.frame = NSRect(x: 0, y: 0, width: frame.size.width, height: frame.size.height)

        let offsetX = inPlace ? 0 : (frame.size.width - image.size.width * scale) / 2
        let offsetY = inPlace ? 0 : (frame.size.height - image.size.height * scale) / 2
        canvas.configure(image: image, scale: scale,
                        origin: NSPoint(x: offsetX, y: offsetY))
        container.addSubview(canvas)

        // 工具栏：底部居中浮动「药丸」，悬浮在截图之上（就地标注时正好压在原截图处）
        let barW = min(frame.size.width - 24, 460)
        let barH: CGFloat = 46
        annoToolbar.frame = NSRect(x: (frame.size.width - barW) / 2, y: 12, width: barW, height: barH)
        annoToolbar.wantsLayer = true
        annoToolbar.layer?.cornerRadius = 12
        annoToolbar.layer?.shadowOpacity = 0.3
        annoToolbar.layer?.shadowRadius = 10
        annoToolbar.layer?.shadowOffset = CGSize(width: 0, height: 2)
        bindToolbar()
        container.addSubview(annoToolbar)

        // 初始选中矩形工具
        canvas.currentTool = .rectangle
        canvas.currentColor = AnnotationColor.red.nsColor
    }

    // MARK: - 工具栏绑定

    private func bindToolbar() {
        annoToolbar.onToolChanged = { [weak canvas] tool in
            canvas?.currentTool = tool
        }
        annoToolbar.onColorChanged = { [weak canvas] color in
            canvas?.currentColor = color
        }
        annoToolbar.onUndo = { [weak canvas] in
            _ = canvas?.undo()
        }
        annoToolbar.onDone = { [weak self] in
            self?.finishEditing()
        }
        annoToolbar.onCancel = { [weak self] in
            self?.cancelEditing()
        }

        canvas.onShapeCountChanged = { [weak annoToolbar] in
            annoToolbar?.setUndoEnabled(self.canvas.canUndo)
        }

        annoToolbar.bindActions(
            undo: { [weak canvas] in _ = canvas?.undo() },
            done: { [weak self] in self?.finishEditing() },
            copy: { [weak self] in self?.copyAndClose() },
            pin: {},
            cancel: { [weak self] in self?.cancelEditing() }
        )
    }

    // 复制合并后的图片到剪贴板并关闭
    private func copyAndClose() {
        guard let merged = canvas.exportImage() else { cancelEditing(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([merged])
        closeEditor()
    }

    // MARK: - 完成 / 取消

    private func finishEditing() {
        guard let merged = canvas.exportImage() else {
            cancelEditing()
            return
        }
        onDone?(merged)
        closeEditor()
    }

    private func cancelEditing() {
        onCancel?()
        closeEditor()
    }

    private func closeEditor() {
        orderOut(nil)
        contentView = nil
    }

    // MARK: - 键盘快捷键

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            cancelEditing()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+Return → 完成
        if event.modifierFlags.contains(.command), event.keyCode == 36 { // Return
            finishEditing()
            return true
        }
        // Cmd+Z → 撤销（转发给 canvas）
        if event.modifierFlags.contains(.command), event.keyCode == 6 { // Z
            _ = self.canvas.undo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - 公开接口

    /// 当前标注画笔数量。
    var shapeCount: Int { /* canvas internal */ 0 } // 由 toolbar 通过回调同步

    override func close() {
        orderOut(nil)
        contentView = nil
    }
}

// MARK: - 编辑器管理器（单例，保持窗口引用）

@MainActor
final class AnnotationEditorManager {
    static let shared = AnnotationEditorManager()
    private weak var currentWindow: AnnotationEditorWindow?

    /// 打开标注编辑器。
    /// - Parameters:
    ///   - image: 截图原始图片
    ///   - screenRect: 选区在全局屏幕坐标中的位置；提供时编辑器就地覆盖该区域（1:1），否则居中显示。
    ///   - onDone: 用户点完成时回调，参数为合并标注后的最终图片
    ///   - onCancel: 用户取消时回调
    func open(image: NSImage,
              screenRect: NSRect? = nil,
              onDone: @escaping (NSImage) -> Void,
              onCancel: @escaping () -> Void) {
        // 先关闭已有编辑器
        currentWindow?.close()

        let win = AnnotationEditorWindow(image: image, screenRect: screenRect)
        win.onDone = { [weak self] mergedImg in
            onDone(mergedImg)
            self?.currentWindow = nil
        }
        win.onCancel = { [weak self] in
            onCancel()
            self?.currentWindow = nil
        }

        currentWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// 关闭当前编辑器（如果有）。
    func closeCurrent() {
        currentWindow?.close()
        currentWindow = nil
    }
}
