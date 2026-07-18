import AppKit
import CoreGraphics

private extension NSScreen {
    /// 取 CG 显示 ID（NSScreen 无直接属性，走 deviceDescription）。
    var cgDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// 一次截图捕获的结果。
struct CaptureResult {
    let image: NSImage
    let sourceRect: NSRect   // 视图坐标系下的选区（用于编辑器还原）
}

/// 单屏的捕获上下文：负责坐标转换与裁剪。
final class ScreenContext {
    let screen: NSScreen
    var cgImage: CGImage?
    let primaryHeight: CGFloat

    init(screen: NSScreen, cgImage: CGImage, primaryHeight: CGFloat) {
        self.screen = screen
        self.cgImage = cgImage
        self.primaryHeight = primaryHeight
    }

    /// 全局 Cocoa 坐标 → 本屏视图局部坐标（y 向上）。
    func globalToView(_ global: NSPoint) -> NSPoint {
        NSPoint(x: global.x - screen.frame.origin.x,
                y: global.y - screen.frame.origin.y)
    }

    /// 全局 CG 坐标矩形（y 向下，原点 primary 左上）→ 本屏视图局部矩形（y 向上）。
    func cgGlobalRectToView(_ cg: CGRect) -> NSRect {
        let viewX = cg.origin.x - screen.frame.origin.x
        let bottomCG = primaryHeight - screen.frame.origin.y
        let viewY = bottomCG - cg.maxY
        return NSRect(x: viewX, y: viewY, width: cg.width, height: cg.height)
    }

    /// 视图局部点 → 全局 CG 点（用于窗口检测）。
    func viewToCGGlobal(_ view: NSPoint) -> CGPoint {
        CGPoint(x: view.x + screen.frame.origin.x,
                y: primaryHeight - (view.y + screen.frame.origin.y))
    }

    /// 从视图局部选区（y 向上，单位=点）裁剪出设备像素图。
    func crop(_ viewRect: NSRect) -> NSImage? {
        let scale = screen.backingScaleFactor
        let x = max(0, viewRect.origin.x * scale)
        let yTop = viewRect.origin.y + viewRect.height  // 视图顶部
        let cgY = max(0, (screen.frame.height - yTop) * scale)
        let w = max(1, viewRect.width * scale)
        let h = max(1, viewRect.height * scale)
        guard let cg = cgImage,
              let sub = cg.cropping(to: CGRect(x: x, y: cgY, width: w, height: h)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: sub)
        let img = NSImage()
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - 选区视图

final class SelectionView: NSView {
    weak var delegate: SelectionViewDelegate?
    var detector: WindowDetector?
    var screenCtx: ScreenContext?
    /// 贴图模式：选中后直接裁图并回调，不弹确认工具条。
    var pinMode: Bool = false
    /// 标注编辑器保存成功后的通知回调（用于 UI 层更新「最近截图」等）。
    var onSaved: ((URL) -> Void)?

    private enum State { case idle, drawing, selected }
    private enum Drag { case none, drawNew, move, resize(Handle) }
    enum Handle: CaseIterable {
        case tl, tr, bl, br, tc, bc, lc, rc
    }

    private var state: State = .idle
    private var drag: Drag = .none
    private var origin: NSPoint = .zero
    private var start: NSPoint = .zero
    private var rect: NSRect?
    private var dragRect0: NSRect = .zero
    private var hoverRect: NSRect?
    private var pendingWindow: NSRect?
    private let clickThreshold: CGFloat = 4

    private let accent = NSColor(red: 0, green: 0.83, blue: 0.42, alpha: 1)
    private let dim: CGFloat = 0.45
    private let handleSize: CGFloat = 9
    private let handleHit: CGFloat = 12

    // MARK: - 就地标注（替代旧 confirmBar + 编辑弹窗流程）

    /// 标注画布（覆盖在选区上方，仅在有标注工具激活时接收鼠标事件）。
    private var annotationCanvas: AnnotationCanvas?

    /// 当前选中的标注工具。nil = 选区操作模式（移动/缩放）；非 nil = 绘制模式。
    private var activeAnnotationTool: AnnotationTool? = nil {
        didSet {
            annotationCanvas?.currentTool = activeAnnotationTool ?? .rectangle
            // 工具切换时通知画布重置拖拽状态
            if oldValue != nil || activeAnnotationTool != nil { needsDisplay = true }
        }
    }

    /// 裁剪好的选区原图（供画布做背景 + 导出合并）。
    private var croppedImage: NSImage?

    /// 集成工具条：左侧标注工具 + 颜色 + 撤销 | 右侧 保存 / 复制 / 贴图 / 取消。
    private lazy var annotToolbar: AnnotationToolbar = {
        let bar = AnnotationToolbar(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        bar.isHidden = true
        // 标注工具切换 → 记录当前工具
        bar.onToolChanged = { [weak self] tool in
            self?.activeAnnotationTool = tool
        }
        // 颜色切换 → 同步到画布
        bar.onColorChanged = { [weak self] color in
            self?.annotationCanvas?.currentColor = color
        }
        // 撤销
        bar.onUndo = { [weak self] in
            guard let canvas = self?.annotationCanvas else { return }
            _ = canvas.undo()
            self?.updateUndoState()
        }
        // 操作按钮绑定
        bar.bindActions(
            undo: {},
            done:   { [weak self] in self?.actSave() },
            copy:   { [weak self] in self?.actCopy() },
            pin:    { [weak self] in self?.actPin() },
            cancel: { [weak self] in self?.actCancel() }
        )
        return bar
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(annotToolbar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var currentRect: NSRect? { rect }

    func setSelection(_ r: NSRect) { rect = r; state = .selected; needsDisplay = true }

    // MARK: 鼠标事件路由

    /// 判断当前是否应将鼠标事件交给标注画布处理。
    private func shouldRouteToCanvas(_ point: NSPoint) -> Bool {
        guard activeAnnotationTool != nil, let r = rect, let _ = annotationCanvas else { return false }
        return r.contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // 点击在工具条上 → 让工具条自己处理
        if !annotToolbar.isHidden && annotToolbar.frame.contains(p) {
            super.mouseDown(with: event)
            return
        }

        // 标注模式 + 点在选区内 → 转发给画布
        if shouldRouteToCanvas(p) {
            window?.makeFirstResponder(annotationCanvas)
            annotationCanvas?.mouseDown(with: event)
            return
        }

        // 以下是原有选区逻辑
        hideAnnotBar()
        if event.clickCount == 2, state == .selected, let r = rect, r.contains(p) {
            delegate?.selectionDidSave(rect: r)
            return
        }
        if state == .idle, let hov = hoverRect {
            pendingWindow = hov
            origin = p; start = p
            rect = NSRect(origin: p, size: .zero)
            state = .drawing; drag = .drawNew
            delegate?.selectionDidStart()
            needsDisplay = true
            return
        }
        if let r = rect, state == .selected {
            if let h = hitHandle(p, r) { drag = .resize(h); start = p; dragRect0 = r; return }
            if r.contains(p) { drag = .move; start = p; dragRect0 = r; return }
        }
        origin = p; start = p
        rect = NSRect(origin: p, size: .zero)
        state = .drawing; drag = .drawNew
        delegate?.selectionDidStart()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if shouldRouteToCanvas(p) {
            annotationCanvas?.mouseDragged(with: event)
            return
        }
        switch drag {
        case .drawNew:
            if pendingWindow != nil {
                if abs(p.x - start.x) < clickThreshold, abs(p.y - start.y) < clickThreshold { return }
                pendingWindow = nil
            }
            rect = normalized(from: origin, to: p)
            needsDisplay = true
        case .move:
            var r = dragRect0.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r = clamp(r)
            rect = r
            delegate?.selectionDidChange(rect: r)
            needsDisplay = true
        case .resize(let h):
            rect = resized(from: dragRect0, handle: h, to: p)
            rect = clamp(rect!)
            delegate?.selectionDidChange(rect: rect!)
            needsDisplay = true
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if shouldRouteToCanvas(p), let canvas = annotationCanvas {
            canvas.mouseUp(with: event)
            updateUndoState()
            return
        }
        switch drag {
        case .drawNew:
            if let w = pendingWindow {
                pendingWindow = nil
                rect = w; state = .selected; drag = .none
                finishSelection(w)
                needsDisplay = true
                return
            }
            guard let r = rect, r.width >= 5, r.height >= 5 else {
                rect = nil; state = .idle; drag = .none; hideAnnotBar(); needsDisplay = true
                delegate?.selectionCancelled()
                return
            }
            state = .selected; drag = .none
            finishSelection(r)
            needsDisplay = true
        case .move, .resize:
            drag = .none
            if let r = rect { finishSelection(r) }
            needsDisplay = true
        case .none: break
        }

        // 拖拽结束后如果工具条可见，重新布局（选区可能移动了）
        if !annotToolbar.isHidden, let r = rect { layoutAnnotBar(for: r) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if state == .idle {
            updateHover(global: NSEvent.mouseLocation)
            return
        }
        if let r = rect, state == .selected {
            if activeAnnotationTool != nil && r.contains(p) {
                NSCursor.crosshair.set()
            } else if hitHandle(p, r) != nil { NSCursor.crosshair.set() }
            else if r.contains(p) { NSCursor.openHand.set() }
            else { NSCursor.crosshair.set() }
        }
    }

    private func updateHover(global: NSPoint) {
        guard let ctx = screenCtx, let det = detector else {
            hoverRect = nil; needsDisplay = true; return
        }
        let cg = ctx.viewToCGGlobal(globalToLocal(global))
        if let w = det.windowAt(cgPoint: cg) {
            let vr = ctx.cgGlobalRectToView(w.frame)
            if hoverRect != vr { hoverRect = vr; needsDisplay = true }
            NSCursor.pointingHand.set()
        } else if hoverRect != nil {
            hoverRect = nil; needsDisplay = true
            NSCursor.crosshair.set()
        }
    }

    private func globalToLocal(_ global: NSPoint) -> NSPoint {
        screenCtx?.globalToView(global) ?? global
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let sctx = screenCtx else { return }

        drawBackground(ctx: ctx, sctx: sctx)

        if state == .idle {
            if let h = hoverRect {
                dimAndCutout(ctx: ctx, cutout: h)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(3)
                ctx.stroke(h.insetBy(dx: -1.5, dy: -1.5))
                drawLabel(ctx: ctx, rect: h)
            } else {
                dimWhole(ctx: ctx)
            }
            return
        }

        guard let r = rect, (state == .drawing || state == .selected) else { return }
        dimAndCutout(ctx: ctx, cutout: r)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r.insetBy(dx: -1, dy: -1))
        if state == .selected {
            drawHandles(ctx: ctx, rect: r)
            drawLabel(ctx: ctx, rect: r)
        }
    }

    private func drawBackground(ctx: CGContext, sctx: ScreenContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        guard let cg = sctx.cgImage else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        ctx.restoreGState()
    }

    private func dimAndCutout(ctx: CGContext, cutout: NSRect) {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(cutout)
        ctx.setFillColor(NSColor.black.withAlphaComponent(dim).cgColor)
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
    }

    private func dimWhole(ctx: CGContext) {
        ctx.setFillColor(NSColor.black.withAlphaComponent(dim).cgColor)
        ctx.fill(bounds)
    }

    private func drawHandles(ctx: CGContext, rect: NSRect) {
        for pos in handlePositions(rect) {
            let hr = NSRect(x: pos.x - handleSize/2, y: pos.y - handleSize/2, width: handleSize, height: handleSize)
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: hr)
        }
    }

    private func drawLabel(ctx: CGContext, rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        let size = text.size(withAttributes: attrs)
        let lr = NSRect(x: rect.origin.x, y: rect.origin.y + rect.height + 4,
                        width: size.width + 8, height: size.height + 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        let bg = CGPath(roundedRect: lr, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(bg); ctx.fillPath()
        text.draw(at: NSPoint(x: lr.origin.x + 4, y: lr.origin.y + 2), withAttributes: attrs)
    }

    // MARK: 命中与缩放

    private func handlePositions(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
         NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.midX, y: r.minY),
         NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY)]
    }

    private func hitHandle(_ p: NSPoint, _ r: NSRect) -> Handle? {
        let positions = handlePositions(r)
        for (i, pos) in positions.enumerated() {
            let hr = NSRect(x: pos.x - handleHit/2, y: pos.y - handleHit/2, width: handleHit, height: handleHit)
            if hr.contains(p) { return Handle.allCases[i] }
        }
        return nil
    }

    private func clamp(_ r: NSRect) -> NSRect {
        let w = min(r.width, bounds.width)
        let h = min(r.height, bounds.height)
        let x = min(max(r.origin.x, 0), bounds.width - w)
        let y = min(max(r.origin.y, 0), bounds.height - h)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func normalized(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func resized(from o: NSRect, handle: Handle, to p: NSPoint) -> NSRect {
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
        return NSRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: - 集成工具条与标注画布

    private func showAnnotBar(for r: NSRect) {
        annotToolbar.isHidden = false
        layoutAnnotBar(for: r)
    }

    private func hideAnnotBar() {
        annotToolbar.isHidden = true
    }

    /// 安装标注画布：裁剪选区图 → 创建画布覆盖选区 → 显示集成工具条。
    private func setupAnnotationCanvas(for r: NSRect) {
        // 先清理旧的画布
        annotationCanvas?.removeFromSuperview()
        annotationCanvas = nil

        guard let img = screenCtx?.crop(r) else { return }
        croppedImage = img

        let canvas = AnnotationCanvas(frame: r)
        canvas.configure(image: img, scale: 1.0, origin: .zero)
        canvas.currentColor = annotToolbar.selectedColor
        canvas.lineWidth = 3
        canvas.onShapeCountChanged = { [weak self] in self?.updateUndoState() }
        addSubview(canvas)
        // 确保工具条在画布之上（通过调整 subview 顺序）
        annotToolbar.removeFromSuperview()
        addSubview(annotToolbar)

        annotationCanvas = canvas
    }

    /// 选区完成：贴图模式直接回调；普通模式安装标注画布 + 弹集成工具条。
    private func finishSelection(_ r: NSRect) {
        if pinMode {
            hideAnnotBar()
            delegate?.selectionDidSave(rect: r)
        } else {
            setupAnnotationCanvas(for: r)
            showAnnotBar(for: r)
        }
    }

    private func layoutAnnotBar(for r: NSRect) {
        let bw: CGFloat = 620
        let bh: CGFloat = 44
        var x = r.midX - bw / 2
        var y = r.maxY + 8                       // flipped 坐标系：下方即 y 增大
        x = min(max(x, 6), bounds.width - bw - 6)
        if y + bh > bounds.height - 6 { y = r.minY - bh - 8 }   // 下方空间不足则翻到上方
        if y < 6 { y = 6 }
        annotToolbar.frame = NSRect(x: x, y: y, width: bw, height: bh)
    }

    /// 更新撤销按钮状态（根据画布是否有可撤销内容）。
    private func updateUndoState() {
        annotToolbar.setUndoEnabled(annotationCanvas?.canUndo ?? false)
    }

    // MARK: - 操作动作

    /// 导出最终图片（有标注则合并，无标注则用原图）。
    private func exportFinalImage() -> NSImage? {
        if let canvas = annotationCanvas, canvas.canUndo {
            return canvas.exportImage()
        }
        return croppedImage
    }

    @objc private func actSave() {
        guard let r = rect, state == .selected else { return }
        hideAnnotBar()
        // 标记完成（释放叠层），但由我们自行输出
        delegate?.markFinished()
        let finalImage = exportFinalImage() ?? screenCtx?.crop(r)
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let url = dir.appendingPathComponent(ScreenshotFlow.buildFilename())
        if let img = finalImage, ScreenshotFlow.savePNG(img, to: url) {
            onSaved?(url)
        }
    }

    @objc private func actCopy() {
        guard let r = rect, state == .selected else { return }
        hideAnnotBar()
        delegate?.markFinished()
        let finalImage = exportFinalImage() ?? screenCtx?.crop(r)
        if let img = finalImage {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
        }
    }

    @objc private func actPin() {
        guard let r = rect, state == .selected else { return }
        hideAnnotBar()
        delegate?.markFinished()
        let finalImage = exportFinalImage() ?? screenCtx?.crop(r)
        if let img = finalImage {
            PinManager.shared.pin(img)
        }
    }

    @objc private func actCancel() {
        hideAnnotBar()
        delegate?.selectionCancelled()
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { actCancel(); return }                          // Esc → 取消
        if state == .selected, event.keyCode == 36 { actSave(); return }        // Return → 保存
        // Cmd+Z → undo annotations
        if event.modifierFlags.contains(.command), event.keyCode == 6 {
            if let canvas = annotationCanvas, canvas.canUndo {
                _ = canvas.undo()
                updateUndoState()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        actCancel()   // 右键 → 取消
    }
}

// MARK: - 选区代理

@MainActor protocol SelectionViewDelegate: AnyObject {
    func selectionDidStart()
    func selectionDidChange(rect: NSRect)
    func selectionDidSave(rect: NSRect)
    func selectionDidCopy(rect: NSRect)
    func selectionDidPin(rect: NSRect)
    func selectionCancelled()
    /// 标注编辑器路径：释放叠层资源但不触发 completion（由编辑器回调处理最终输出）。
    func markFinished()
}

// MARK: - 叠层窗口

final class OverlayWindow: NSWindow {
    let screenCtx: ScreenContext
    // borderless 窗口默认 canBecomeKey=false，导致 makeKeyAndOrderFront 无法生效、keyDown 收不到 Esc
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private(set) lazy var selectionView: SelectionView = {
        let v = SelectionView(frame: NSRect(origin: .zero, size: screenCtx.screen.frame.size))
        v.screenCtx = screenCtx
        return v
    }()

    init(ctx: ScreenContext) {
        self.screenCtx = ctx
        let f = ctx.screen.frame
        super.init(contentRect: f, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = selectionView
    }

    func beginDetection() {
        let det = WindowDetector()
        det.refresh()
        selectionView.detector = det
    }
}

// MARK: - 捕获会话

@MainActor final class CaptureSession {
    /// 是否已有截图会话进行中（防止重复触发快捷键叠加多层叠层）。
    private static var isCapturing = false

    /// 开始一次截图捕获。
    /// - mode: .region/.window 显示叠层（含窗口吸附，单击窗口即捕）；.full 直接截取光标所在屏。
    /// - pin: true 时区域/窗口模式选中即直接贴图（不弹确认工具条）。
    static func run(mode: CaptureMode = .region, defaultSaveDir: URL? = nil, pin: Bool = false,
                    completion: @escaping (CaptureResult?) -> Void) {
        guard checkScreenRecordingPermission() else {
            completion(nil); return
        }
        guard !isCapturing else {
            // 已有截图会话进行中，忽略重复触发
            completion(nil); return
        }
        if mode == .full {
            isCapturing = true
            captureFull { result in
                isCapturing = false
                completion(result)
            }
            return
        }
        let primaryHeight = NSScreen.screens[0].frame.height
        var overlays: [OverlayWindow] = []
        for screen in NSScreen.screens {
            guard let id = screen.cgDisplayID, let cg = CGDisplayCreateImage(id) else { continue }
            let ctx = ScreenContext(screen: screen, cgImage: cg, primaryHeight: primaryHeight)
            let win = OverlayWindow(ctx: ctx)
            overlays.append(win)
        }
        guard !overlays.isEmpty else { completion(nil); return }

        let state = SessionState()
        isCapturing = true
        for o in overlays {
            let delegate = Delegate(overlay: o, overlays: overlays, state: state,
                                    defaultSaveDir: defaultSaveDir, pin: pin, completion: completion)
            o.selectionView.delegate = delegate
            o.selectionView.pinMode = pin
            retainedDelegates.append(delegate)   // 强引用，防止 run() 返回后 Delegate 被释放致工具条按钮失效
            o.beginDetection()
            o.makeKeyAndOrderFront(nil)
            o.makeFirstResponder(o.selectionView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 全屏截取（光标所在屏）

    private static func captureFull(completion: @escaping (CaptureResult?) -> Void) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        guard let id = screen.cgDisplayID, let cg = CGDisplayCreateImage(id) else { completion(nil); return }
        let img = imageFrom(cg)
        completion(CaptureResult(image: img,
                                sourceRect: NSRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))))
    }

    // MARK: - 权限 / 工具

    static func checkScreenRecordingPermission() -> Bool {
        let stream = CGDisplayStream(
            dispatchQueueDisplay: CGMainDisplayID(),
            outputWidth: 1, outputHeight: 1,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: nil, queue: DispatchQueue.global(),
            handler: { _, _, _, _ in }
        )
        return stream != nil
    }

    nonisolated private static func imageFrom(_ cg: CGImage) -> NSImage {
        let img = NSImage()
        img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        return img
    }

    // MARK: - 会话状态 / 代理

    /// 强引用活动中的 Delegate，避免 run() 返回后 Delegate 被 ARC 释放
    /// （SelectionView.delegate 是 weak），否则用户稍后点工具条按钮时 delegate 已为 nil、遮罩关不掉。
    private static var retainedDelegates: [Delegate] = []
    private static func release(state: SessionState) {
        retainedDelegates.removeAll { $0.state === state }
        isCapturing = false
    }

    /// 跨叠层共享的「已结束」标记，避免多屏误触发多次完成。
    final class SessionState { var finished = false }

    @MainActor final class Delegate: SelectionViewDelegate {
        let overlay: OverlayWindow
        let overlays: [OverlayWindow]
        let state: SessionState
        let completion: (CaptureResult?) -> Void
        let defaultSaveDir: URL?
        let pin: Bool
        init(overlay: OverlayWindow, overlays: [OverlayWindow], state: SessionState,
             defaultSaveDir: URL? = nil, pin: Bool = false,
             completion: @escaping (CaptureResult?) -> Void) {
            self.overlay = overlay; self.overlays = overlays; self.state = state
            self.defaultSaveDir = defaultSaveDir; self.pin = pin; self.completion = completion
        }
        func selectionDidStart() {}

        /// 主动释放所有叠层持有的整屏大图（CGImage），避免会话结束后大图因被间接引用而常驻内存。
        private func freeScreens() {
            overlay.screenCtx.cgImage = nil
            for o in overlays { o.screenCtx.cgImage = nil }
        }
        func selectionDidChange(rect: NSRect) {}
        func selectionCancelled() {
            guard !state.finished else { return }
            state.finished = true
            for o in overlays { o.orderOut(nil) }
            freeScreens()
            CaptureSession.release(state: state)
            completion(nil)
        }
        /// 标注编辑器路径：释放叠层 + 标记完成，但由编辑器回调决定最终输出。
        func markFinished() {
            guard !state.finished else { return }
            state.finished = true
            for o in overlays { o.orderOut(nil) }
            freeScreens()
            CaptureSession.release(state: state)
            // 不调用 completion —— 由 AnnotationEditorManager.onDone/onCancel 处理
        }

        func selectionDidSave(rect: NSRect) {
            guard !state.finished else { return }
            state.finished = true
            let image = overlay.screenCtx.crop(rect)
            for o in overlays { o.orderOut(nil) }
            freeScreens()
            CaptureSession.release(state: state)
            // 贴图模式：把裁好的图交回上层，由 ScreenshotFlow 调用 PinManager 贴出
            if pin, let img = image {
                completion(CaptureResult(image: img, sourceRect: rect))
                return
            }
            if let img = image {
                let dir = defaultSaveDir
                    ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory())
                let url = dir.appendingPathComponent(ScreenshotFlow.buildFilename())
                _ = ScreenshotFlow.savePNG(img, to: url)
            }
            completion(nil)
        }

        func selectionDidCopy(rect: NSRect) {
            guard !state.finished else { return }
            state.finished = true
            let image = overlay.screenCtx.crop(rect)
            for o in overlays { o.orderOut(nil) }
            freeScreens()
            CaptureSession.release(state: state)
            if let img = image {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([img])
            }
            completion(nil)
        }

        func selectionDidPin(rect: NSRect) {
            guard !state.finished else { return }
            state.finished = true
            let image = overlay.screenCtx.crop(rect)
            for o in overlays { o.orderOut(nil) }
            freeScreens()
            CaptureSession.release(state: state)
            if let img = image {
                PinManager.shared.pin(img)
            }
            completion(nil)
        }
    }
}
