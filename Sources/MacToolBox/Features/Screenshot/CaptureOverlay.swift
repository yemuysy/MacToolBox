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
struct ScreenContext {
    let screen: NSScreen
    let cgImage: CGImage
    let primaryHeight: CGFloat

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
        guard let sub = cgImage.cropping(to: CGRect(x: x, y: cgY, width: w, height: h)) else { return nil }
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

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var currentRect: NSRect? { rect }

    func setSelection(_ r: NSRect) { rect = r; state = .selected; needsDisplay = true }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
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
        switch drag {
        case .drawNew:
            if let w = pendingWindow {
                pendingWindow = nil
                rect = w; state = .selected; drag = .none
                delegate?.selectionDidComplete(rect: w, isWindow: true)
                needsDisplay = true
                return
            }
            guard let r = rect, r.width >= 5, r.height >= 5 else {
                rect = nil; state = .idle; drag = .none; needsDisplay = true
                delegate?.selectionCancelled()
                return
            }
            state = .selected; drag = .none
            delegate?.selectionDidComplete(rect: r, isWindow: false)
        case .move, .resize:
            if let r = rect { delegate?.selectionDidComplete(rect: r, isWindow: false) }
            drag = .none
        case .none: break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if state == .idle {
            updateHover(global: NSEvent.mouseLocation)
            return
        }
        if let r = rect, state == .selected {
            if hitHandle(p, r) != nil { NSCursor.crosshair.set() }
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

    /// 把全局 Cocoa 点转成视图局部点。
    private func globalToLocal(_ global: NSPoint) -> NSPoint {
        screenCtx?.globalToView(global) ?? global
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let sctx = screenCtx else { return }

        // 背景快照（已垂直翻转绘制）
        drawBackground(ctx: ctx, sctx: sctx)

        if state == .idle, let h = hoverRect {
            dimAndCutout(ctx: ctx, cutout: h)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(h.insetBy(dx: -1.5, dy: -1.5))
            drawLabel(ctx: ctx, rect: h)
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
        ctx.draw(sctx.cgImage, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
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
}

// MARK: - 选区代理

@MainActor protocol SelectionViewDelegate: AnyObject {
    func selectionDidStart()
    func selectionDidChange(rect: NSRect)
    func selectionDidComplete(rect: NSRect, isWindow: Bool)
    func selectionCancelled()
}

// MARK: - 叠层窗口

final class OverlayWindow: NSWindow {
    let screenCtx: ScreenContext
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
    /// 开始一次截图捕获。
    /// - mode: .region/.window 显示叠层（含窗口吸附，单击窗口即捕）；.full 直接截取光标所在屏。
    static func run(mode: CaptureMode = .region, completion: @escaping (CaptureResult?) -> Void) {
        guard checkScreenRecordingPermission() else {
            completion(nil); return
        }
        if mode == .full {
            captureFull(completion: completion)
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
        for o in overlays {
            let delegate = Delegate(overlay: o, overlays: overlays, state: state, completion: completion)
            o.selectionView.delegate = delegate
            o.beginDetection()
            o.makeKeyAndOrderFront(nil)
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

    // MARK: - 长截图入口：截取最上层窗口完整可见图（v1，待接滚动拼接）

    nonisolated static func captureFrontmostWindowFull() -> NSImage? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates: [(CGWindowID, CGRect, Int)] = infoList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                  let layer = info[kCGWindowLayer as String] as? Int else { return nil }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsNS as CFDictionary, &rect) else { return nil }
            let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            return (id, rect, layer)
        }
        guard let top = candidates.max(by: { $0.2 < $1.2 }) else { return nil }
        guard let cg = CGWindowListCreateImage(top.1, .optionIncludingWindow, top.0, .bestResolution) else { return nil }
        return imageFrom(cg)
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

    /// 跨叠层共享的「已结束」标记，避免多屏误触发多次完成。
    final class SessionState { var finished = false }

    @MainActor final class Delegate: SelectionViewDelegate {
        let overlay: OverlayWindow
        let overlays: [OverlayWindow]
        let state: SessionState
        let completion: (CaptureResult?) -> Void
        init(overlay: OverlayWindow, overlays: [OverlayWindow], state: SessionState,
             completion: @escaping (CaptureResult?) -> Void) {
            self.overlay = overlay; self.overlays = overlays; self.state = state; self.completion = completion
        }
        func selectionDidStart() {}
        func selectionDidChange(rect: NSRect) {}
        func selectionDidComplete(rect: NSRect, isWindow: Bool) {
            guard !state.finished else { return }
            state.finished = true
            for o in overlays { o.orderOut(nil) }
            if let img = overlay.screenCtx.crop(rect) {
                completion(CaptureResult(image: img, sourceRect: rect))
            } else {
                completion(nil)
            }
        }
        func selectionCancelled() {
            guard !state.finished else { return }
            state.finished = true
            for o in overlays { o.orderOut(nil) }
            completion(nil)
        }
    }
}
