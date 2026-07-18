import AppKit

// MARK: - 标注画布：叠加在截图图片上，响应鼠标绘制各种形状。

final class AnnotationCanvas: NSView {

    // MARK: - 状态

    /// 背景截图（不可变，仅用于 draw）。
    private(set) var backgroundImage: NSImage?

    /// 已完成的标注笔迹（支持 undo 弹出最后一笔）。
    private var shapes: [AnnotationShape] = []

    /// 当前正在绘制的临时形状（拖拽过程中实时预览）。
    private var previewShape: AnnotationShape?

    /// 当前选中的工具。
    var currentTool: AnnotationTool = .rectangle

    /// 当前画笔颜色。
    var currentColor: NSColor = AnnotationColor.red.nsColor

    /// 当前线宽（矩形/椭圆/箭头/画笔通用）。
    var lineWidth: CGFloat = 3

    /// 画布缩放比例（1.0 = 原始大小）。
    private var scale: CGFloat = 1.0

    /// 图片在画布中的偏移（居中显示时使用）。
    private var imageOrigin: NSPoint = .zero

    /// 画笔路径收集（pen 工具专用）。
    private var penPoints: [NSPoint] = []

    /// 鼠标按下起点。
    private var mouseDownPoint: NSPoint = .zero

    /// 是否正在绘制中。
    private var isDrawing = false

    /// Undo 栈深度限制。
    private let maxUndoCount = 100

    // MARK: - 回调

    /// 形状数量变化时通知工具栏更新 undo 按钮状态。
    var onShapeCountChanged: (() -> Void)?

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 配置

    func configure(image: NSImage, scale: CGFloat, origin: NSPoint) {
        self.backgroundImage = image
        self.scale = scale
        self.imageOrigin = origin
        needsDisplay = true
    }

    /// 清除所有标注。
    func clearAll() {
        shapes.removeAll()
        previewShape = nil
        penPoints.removeAll()
        isDrawing = false
        notifyChange()
        needsDisplay = true
    }

    /// 撤销最后一笔。返回是否成功撤销。
    @discardableResult
    func undo() -> Bool {
        guard !shapes.isEmpty else { return false }
        shapes.removeLast()
        previewShape = nil
        notifyChange()
        needsDisplay = true
        return true
    }

    /// 是否可以撤销。
    var canUndo: Bool { !shapes.isEmpty }

    /// 导出合并后的最终图片（原图 + 所有标注渲染在一起）。
    func exportImage() -> NSImage? {
        guard let img = backgroundImage else { return nil }
        let size = img.size

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        ctx.saveGState()

        // Flip 坐标系（NSImage / CG 一致）
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        // 绘制原图
        img.draw(in: CGRect(origin: .zero, size: size))

        // 绘制所有标注（坐标从视图空间映射回图片空间）
        for shape in shapes {
            shape.draw(in: ctx)
        }

        ctx.restoreGState()

        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        // 画背景图
        if let img = backgroundImage {
            let drawRect = CGRect(
                x: imageOrigin.x,
                y: imageOrigin.y,
                width: img.size.width * scale,
                height: img.size.height * scale
            )
            img.draw(in: drawRect)
        }

        // 画已完成的所有形状（应用缩放+偏移，使其与显示中的背景图对齐）
        ctx.saveGState()
        ctx.translateBy(x: imageOrigin.x, y: imageOrigin.y)
        ctx.scaleBy(x: scale, y: scale)
        for shape in shapes {
            shape.draw(in: ctx)
        }

        // 画当前拖拽中的预览形状
        if let preview = previewShape {
            preview.draw(in: ctx)
        }
        ctx.restoreGState()

        ctx.restoreGState()
    }

    // MARK: - 鼠标事件 → 视图坐标转换

    /// 把 Cocoa 鼠标事件位置转为画布内坐标（考虑缩放和偏移）。
    private func canvasPoint(_ event: NSEvent) -> NSPoint {
        let loc = convert(event.locationInWindow, from: nil)
        return NSPoint(
            x: (loc.x - imageOrigin.x) / scale,
            y: (loc.y - imageOrigin.y) / scale
        )
    }

    // MARK: - 鼠标交互

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = canvasPoint(event)
        mouseDownPoint = pt
        isDrawing = true

        switch currentTool {
        case .text:
            // 文字工具：点击弹出输入框
            showTextInput(at: pt)
            isDrawing = false

        case .pen:
            penPoints = [pt]

        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawing else { return }
        let cur = canvasPoint(event)

        switch currentTool {
        case .rectangle:
            let r = normalizedRect(from: mouseDownPoint, to: cur)
            previewShape = .rect(rect: r, lineWidth: lineWidth, color: currentColor)

        case .ellipse:
            let r = normalizedRect(from: mouseDownPoint, to: cur)
            previewShape = .ellipse(rect: r, lineWidth: lineWidth, color: currentColor)

        case .arrow:
            previewShape = .arrow(from: mouseDownPoint, to: cur, lineWidth: lineWidth, color: currentColor)

        case .pen:
            penPoints.append(cur)
            previewShape = .pen(points: penPoints, lineWidth: lineWidth, color: currentColor)

        case .mosaic:
            let r = normalizedRect(from: mouseDownPoint, to: cur)
            previewShape = .mosaic(rect: r)

        case .text:
            break
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawing else { return }
        isDrawing = false

        if let preview = previewShape {
            shapes.append(preview)
            if shapes.count > maxUndoCount { shapes.removeFirst() }
            previewShape = nil
            notifyChange()
        }

        penPoints.removeAll()
        needsDisplay = true
    }

    // MARK: - 文字输入

    private func showTextInput(at point: NSPoint) {
        // 在点击位置创建一个临时 NSTextField，编辑完成后提交 text shape
        let field = NSTextField(frame: CGRect(
            x: point.x * scale + imageOrigin.x,
            y: point.y * scale + imageOrigin.y,
            width: 200, height: 28
        ))
        field.placeholderString = "输入文字…"
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        field.textColor = currentColor
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        // Cmd+Z → undo
        if event.modifierFlags.contains(.command), event.keyCode == 6 { // Z
            _ = undo()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - 辅助方法

    /// 从两点构建正方向矩形（minX/minY 为原点）。
    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    private func notifyChange() { onShapeCountChanged?() }
}

// MARK: - NSTextFieldDelegate（文字输入完成后提交）

extension AnnotationCanvas: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        guard let str = field.stringValue as String?, !str.isEmpty else {
            field.removeFromSuperview()
            return
        }

        // 将字段位置转回图片坐标系
        let originInView = field.frame.origin
        let imgPoint = NSPoint(
            x: (originInView.x - imageOrigin.x) / scale,
            y: (originInView.y - imageOrigin.y) / scale
        )

        shapes.append(.text(string: str, origin: imgPoint, color: currentColor, fontSize: 18))
        if shapes.count > 100 { shapes.removeFirst() }
        field.removeFromSuperview()
        notifyChange()
        needsDisplay = true
    }

    /// 回车键也确认文字
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }
}
