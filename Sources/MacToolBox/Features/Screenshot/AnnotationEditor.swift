import AppKit
import Vision

/// 标注画布：显示底图 + 标注，支持创建/选择/移动/缩放/改色/内联文字编辑/撤销重做。
final class AnnotationCanvas: NSView {
    var baseImage: NSImage? {
        didSet {
            if let img = baseImage { imageSize = img.size } else { imageSize = .zero }
            annotations = []; undoStack = []; redoStack = []
            selectedId = nil; recomputeLayout(); needsDisplay = true
        }
    }
    private(set) var imageSize: NSSize = .zero
    private var annotations: [any Annotation] = []
    private var undoStack: [[any Annotation]] = []
    private var redoStack: [[any Annotation]] = []

    var tool: AnnotationTool = .select
    var currentColor: NSColor = AnnotationPalette.default
    var currentLineWidth: CGFloat = 4
    var currentFontSize: CGFloat = 20
    var onAnnotationsChanged: (() -> Void)?

    private var selectedId: UUID?
    private var scale: CGFloat = 1
    private var offset: NSPoint = .zero

    private var dragMode: DragMode = .none
    private enum DragMode { case none, drawNew, move, resize(SelectionViewHandle) }
    private var dragStart: NSPoint = .zero
    private var dragOrig: NSRect = .zero
    private var pendingPoints: [NSPoint] = []
    private var editingField: NSTextField?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 布局

    private func recomputeLayout() {
        guard let img = baseImage, img.size.width > 0 else { scale = 1; offset = .zero; return }
        let bw = bounds.width, bh = bounds.height
        scale = min(bw / img.size.width, bh / img.size.height)
        offset = NSPoint(x: (bw - img.size.width * scale) / 2,
                         y: (bh - img.size.height * scale) / 2)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { recomputeLayout(); super.resizeSubviews(withOldSize: oldSize) }

    private func toView(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
    private func toImage(_ p: NSPoint) -> NSPoint { NSPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill(); bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext, let img = baseImage else { return }
        let vr = NSRect(x: offset.x, y: offset.y, width: imageSize.width * scale, height: imageSize.height * scale)
        img.draw(in: vr)
        renderAnnotations(in: ctx)
        drawSelectionOverlay(in: ctx)
    }

    private func renderAnnotations(in ctx: CGContext) {
        let toView = { [weak self] (p: NSPoint) -> NSPoint in self?.toView(p) ?? p }
        for ann in annotations { ann.draw(in: ctx, toView: toView, scale: scale) }
    }

    private func drawSelectionOverlay(in ctx: CGContext) {
        guard let id = selectedId, let ann = annotations.first(where: { $0.id == id }) else { return }
        let r = ann.boundingRect
        let vr = NSRect(x: r.origin.x * scale + offset.x, y: r.origin.y * scale + offset.y,
                        width: r.width * scale, height: r.height * scale)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5 / scale)
        ctx.stroke(vr)
        if ann is RectAnnotation || ann is EllipseAnnotation {
            for pos in handlePositions(vr) {
                let hr = NSRect(x: pos.x - 5, y: pos.y - 5, width: 10, height: 10)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(hr); ctx.stroke(hr)
            }
        }
    }

    private func handlePositions(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
         NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.midX, y: r.minY),
         NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY)]
    }

    // MARK: 撤销/重做

    private func snapshot() { undoStack.append(annotations); redoStack.removeAll() }
    func undo() { if let prev = undoStack.popLast() { redoStack.append(annotations); annotations = prev; selectedId = nil; changed() } }
    func redo() { if let next = redoStack.popLast() { undoStack.append(annotations); annotations = next; changed() } }

    private func changed() { needsDisplay = true; onAnnotationsChanged?() }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))

        // 双击文字编辑
        if event.clickCount >= 2, let id = selectedId,
           let ann = annotations.first(where: { $0.id == id }) as? TextAnnotation {
            beginTextEdit(ann); return
        }

        // 命中已选中的标注 → 移动/缩放
        if let id = selectedId, let ann = annotations.first(where: { $0.id == id }) {
            let vr = viewRect(ann.boundingRect)
            if ann is RectAnnotation || ann is EllipseAnnotation, let h = hitHandle(convert(event.locationInWindow, from: nil), vr) {
                dragMode = .resize(h); dragStart = toImage(convert(event.locationInWindow, from: nil)); dragOrig = ann.boundingRect
                return
            }
            if ann.boundingRect.contains(p) {
                dragMode = .move; dragStart = p; snapshot(); return
            }
        }

        // 命中某个标注 → 选中
        if let hit = topHit(p) {
            selectedId = hit.id; dragMode = .move; dragStart = p; snapshot(); needsDisplay = true
            return
        }

        // 空白 → 依工具新建
        selectedId = nil
        beginCreate(at: p, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let pv = convert(event.locationInWindow, from: nil)
        let p = toImage(pv)
        switch dragMode {
        case .none: break
        case .move:
            guard let id = selectedId else { break }
            let delta = NSPoint(x: p.x - dragStart.x, y: p.y - dragStart.y)
            if let i = annotations.firstIndex(where: { $0.id == id }) {
                annotations[i] = annotations[i].translated(by: delta)
                needsDisplay = true
            }
        case .drawNew:
            if let i = annotations.firstIndex(where: { $0.id == selectedId }) {
                annotations[i] = updateDraft(annotations[i], to: p)
                needsDisplay = true
            } else if tool == .pen {
                pendingPoints.append(p)
                addPenIfNeeded(p)
            }
        case .resize(let h):
            guard let id = selectedId else { break }
            let nr = resizedRect(dragOrig, handle: h, to: p)
            if let i = annotations.firstIndex(where: { $0.id == id }) {
                annotations[i] = resizeAnnotation(annotations[i], to: nr)
                needsDisplay = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .drawNew:
            finalizeDraft()
        default: break
        }
        dragMode = .none
    }

    // MARK: 创建标注

    private func beginCreate(at p: NSPoint, event: NSEvent) {
        snapshot()
        let ann: any Annotation
        switch tool {
        case .arrow: ann = ArrowAnnotation(start: p, end: p, color: currentColor, lineWidth: currentLineWidth)
        case .rect: ann = RectAnnotation(rect: NSRect(origin: p, size: .zero), color: currentColor, lineWidth: currentLineWidth, filled: false)
        case .ellipse: ann = EllipseAnnotation(rect: NSRect(origin: p, size: .zero), color: currentColor, lineWidth: currentLineWidth, filled: false)
        case .text:
            let t = TextAnnotation(origin: p, text: "文字", color: currentColor, fontSize: currentFontSize)
            annotations.append(t); selectedId = t.id; changed()
            beginTextEdit(t); return
        case .numbered:
            let n = (annotations.compactMap { ($0 as? NumberedAnnotation)?.number }.max() ?? 0) + 1
            ann = NumberedAnnotation(center: p, number: n, color: currentColor, radius: 14)
        case .mosaic:
            ann = MosaicAnnotation(rect: NSRect(origin: p, size: .zero), pixelated: NSImage())
        case .pen:
            pendingPoints = [p]
            ann = PenAnnotation(points: [p], color: currentColor, lineWidth: currentLineWidth)
        case .select, .colorPick: return
        }
        annotations.append(ann); selectedId = ann.id; dragMode = .drawNew; needsDisplay = true
    }

    private func updateDraft(_ a: any Annotation, to p: NSPoint) -> any Annotation {
        switch a {
        case let x as ArrowAnnotation: return ArrowAnnotation(start: x.start, end: p, color: x.color, lineWidth: x.lineWidth)
        case let x as RectAnnotation: return RectAnnotation(rect: normalized(x.rect.origin, p), color: x.color, lineWidth: x.lineWidth, filled: x.filled)
        case let x as EllipseAnnotation: return EllipseAnnotation(rect: normalized(x.rect.origin, p), color: x.color, lineWidth: x.lineWidth, filled: x.filled)
        case let x as MosaicAnnotation:
            let r = normalized(x.rect.origin, p)
            if let img = baseImage { return MosaicAnnotation.make(rect: r, base: img) } else { return x }
        default: return a
        }
    }

    private func addPenIfNeeded(_ p: NSPoint) {
        guard let i = annotations.firstIndex(where: { $0.id == selectedId }) else { return }
        if case let pen as PenAnnotation = annotations[i] {
            var pts = pen.points; pts.append(p)
            annotations[i] = PenAnnotation(points: pts, color: pen.color, lineWidth: pen.lineWidth)
        }
    }

    private func finalizeDraft() {
        guard let id = selectedId, let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        let a = annotations[i]
        // 丢弃过小的标注
        let tooSmall: Bool
        switch a {
        case let x as RectAnnotation: tooSmall = x.rect.width < 4 || x.rect.height < 4
        case let x as EllipseAnnotation: tooSmall = x.rect.width < 4 || x.rect.height < 4
        case let x as ArrowAnnotation: tooSmall = hypot(x.end.x - x.start.x, x.end.y - x.start.y) < 4
        case let x as MosaicAnnotation: tooSmall = x.rect.width < 4 || x.rect.height < 4
        case let x as PenAnnotation: tooSmall = x.points.count < 2
        default: tooSmall = false
        }
        if tooSmall { annotations.remove(at: i); selectedId = nil }
        needsDisplay = true; onAnnotationsChanged?()
    }

    private func normalized(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: 命中

    private func topHit(_ p: NSPoint) -> (any Annotation)? {
        for ann in annotations.reversed() where ann.contains(p) { return ann }
        return nil
    }

    private func hitHandle(_ p: NSPoint, _ r: NSRect) -> SelectionViewHandle? {
        let positions = handlePositions(r)
        let handles: [SelectionViewHandle] = [.tl, .tr, .bl, .br, .tc, .bc, .lc, .rc]
        for (i, pos) in positions.enumerated() {
            if hypot(pos.x - p.x, pos.y - p.y) <= 8 { return handles[i] }
        }
        return nil
    }

    private func viewRect(_ r: NSRect) -> NSRect {
        NSRect(x: r.origin.x * scale + offset.x, y: r.origin.y * scale + offset.y,
               width: r.width * scale, height: r.height * scale)
    }

    private enum SelectionViewHandle { case tl, tr, bl, br, tc, bc, lc, rc }

    private func resizedRect(_ o: NSRect, handle: SelectionViewHandle, to p: NSPoint) -> NSRect {
        var minX = o.minX, minY = o.minY, maxX = o.maxX, maxY = o.maxY
        switch handle {
        case .tl: minX = p.x; maxY = p.y
        case .tr: maxX = p.x; maxY = p.y
        case .bl: minX = p.x; minY = p.y
        case .br: maxX = p.x; minY = p.y
        case .tc: maxY = p.y
        case .bc: minY = p.y
        case .lc: minX = p.x
        case .rc: maxX = p.x
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func resizeAnnotation(_ a: any Annotation, to nr: NSRect) -> any Annotation {
        switch a {
        case let x as RectAnnotation: return RectAnnotation(rect: nr, color: x.color, lineWidth: x.lineWidth, filled: x.filled)
        case let x as EllipseAnnotation: return EllipseAnnotation(rect: nr, color: x.color, lineWidth: x.lineWidth, filled: x.filled)
        default: return a
        }
    }

    // MARK: 颜色/线宽

    func applyColor(_ c: NSColor) {
        currentColor = c
        if let id = selectedId, let i = annotations.firstIndex(where: { $0.id == id }) {
            snapshot(); annotations[i] = annotations[i].withColor(c); changed()
        }
    }
    func applyLineWidth(_ w: CGFloat) {
        currentLineWidth = w
        if let id = selectedId, let i = annotations.firstIndex(where: { $0.id == id }) {
            snapshot(); annotations[i] = annotations[i].withLineWidth(w); changed()
        }
    }

    // MARK: 内联文字编辑

    private func beginTextEdit(_ ann: TextAnnotation) {
        editingField?.removeFromSuperview()
        let vr = viewRect(ann.boundingRect)
        let field = NSTextField(frame: NSRect(x: vr.origin.x, y: vr.origin.y, width: max(vr.width, 120), height: max(vr.height, 24)))
        field.stringValue = ann.text
        field.font = NSFont.systemFont(ofSize: currentFontSize * scale, weight: .medium)
        field.textColor = ann.color
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(commitTextEdit(_:))
        field.cell?.wraps = true
        addSubview(field)
        editingField = field
        window?.makeFirstResponder(field)
    }

    @objc private func commitTextEdit(_ sender: NSTextField) {
        guard let id = selectedId, let i = annotations.firstIndex(where: { $0.id == id }),
              let ann = annotations[i] as? TextAnnotation else { editingField?.removeFromSuperview(); editingField = nil; return }
        let text = sender.stringValue.isEmpty ? "文字" : sender.stringValue
        annotations[i] = TextAnnotation(origin: ann.origin, text: text, color: ann.color, fontSize: ann.fontSize)
        editingField?.removeFromSuperview(); editingField = nil
        needsDisplay = true; onAnnotationsChanged?()
    }

    // MARK: 合成导出图

    func compose() -> NSImage {
        guard let img = baseImage else { return NSImage() }
        let out = NSImage(size: imageSize)
        out.lockFocus()
        defer { out.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return out }
        img.draw(in: NSRect(origin: .zero, size: imageSize))
        let toView = { (p: NSPoint) -> NSPoint in p }
        for ann in annotations { ann.draw(in: ctx, toView: toView, scale: 1) }
        return out
    }

    func hasAnnotations() -> Bool { !annotations.isEmpty }
}
