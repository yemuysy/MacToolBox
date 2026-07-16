import AppKit
import Foundation

/// 半透明全屏选区覆盖层：用户拖拽选择矩形区域，支持移动和调整选区，类似 PixPin。
/// 回调 NSScreen 坐标系（左下原点）的 CGRect。
@MainActor
final class RegionSelector {

    static func begin(completion: @escaping (CGRect?) -> Void) {
        let screens = NSScreen.screens
        let global = screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !global.isEmpty else { completion(nil); return }

        let panel = NSPanel(
            contentRect: global,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false

        let view = SelectionView(frame: global)
        view.onCommit = { localRect in
            panel.orderOut(nil)
            if let monitor = view.escMonitor {
                NSEvent.removeMonitor(monitor)
                view.escMonitor = nil
            }
            if let localRect {
                let g = CGRect(
                    x: global.origin.x + localRect.origin.x,
                    y: global.origin.y + localRect.origin.y,
                    width: localRect.width,
                    height: localRect.height
                )
                completion(g)
            } else {
                completion(nil)
            }
        }
        panel.contentView = view
        panel.makeFirstResponder(view)

        // 全局监听 ESC + Enter
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                view.cancel()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                if view.state == .selected {
                    view.confirm()
                    return nil
                }
            }
            return event
        }
        view.escMonitor = monitor

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 状态与拖拽句柄

private enum SelectionState {
    case idle          // 等待首次点击
    case selecting    // 正在拖拽创建选区
    case selected     // 选区完成，可移动/调整
}

/// 8 个调整句柄
private enum DragHandle: CaseIterable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight

    var cursor: NSCursor {
        switch self {
        case .topLeft, .bottomRight:     return NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)!, hotSpot: NSPoint(x: 8, y: 8))
        case .top, .bottom:              return .resizeUpDown
        case .left, .right:              return .resizeLeftRight
        case .topRight, .bottomLeft:     return NSCursor(image: NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left", accessibilityDescription: nil)!, hotSpot: NSPoint(x: 8, y: 8))
        }
    }

    /// 根据鼠标偏移调整选区 rect
    func adjust(rect: CGRect, by delta: CGSize, minSize: CGFloat = 10) -> CGRect {
        var r = rect
        switch self {
        case .topLeft:
            r.origin.x = min(rect.maxX - minSize, r.origin.x + delta.width)
            r.origin.y = min(rect.maxY - minSize, r.origin.y + delta.height)
            r.size.width = max(minSize, rect.maxX - r.origin.x)
            r.size.height = max(minSize, rect.maxY - r.origin.y)
        case .top:
            r.origin.y = min(rect.maxY - minSize, r.origin.y + delta.height)
            r.size.height = max(minSize, rect.maxY - r.origin.y)
        case .topRight:
            r.origin.y = min(rect.maxY - minSize, r.origin.y + delta.height)
            r.size.width = max(minSize, rect.width + delta.width)
            r.size.height = max(minSize, rect.maxY - r.origin.y)
        case .left:
            r.origin.x = min(rect.maxX - minSize, r.origin.x + delta.width)
            r.size.width = max(minSize, rect.maxX - r.origin.x)
        case .right:
            r.size.width = max(minSize, rect.width + delta.width)
        case .bottomLeft:
            r.origin.x = min(rect.maxX - minSize, r.origin.x + delta.width)
            r.size.width = max(minSize, rect.maxX - r.origin.x)
            r.size.height = max(minSize, rect.height + delta.height)
        case .bottom:
            r.size.height = max(minSize, rect.height + delta.height)
        case .bottomRight:
            r.size.width = max(minSize, rect.width + delta.width)
            r.size.height = max(minSize, rect.height + delta.height)
        }
        return r
    }

    /// 句柄区域（以 rect 的角/边为中心的 8x8 热区）
    func rect(in r: CGRect) -> CGRect {
        let half: CGFloat = 4
        switch self {
        case .topLeft:      return CGRect(x: r.minX - half, y: r.maxY - half, width: half*2, height: half*2)
        case .top:          return CGRect(x: r.midX - half, y: r.maxY - half, width: half*2, height: half*2)
        case .topRight:     return CGRect(x: r.maxX - half, y: r.maxY - half, width: half*2, height: half*2)
        case .left:         return CGRect(x: r.minX - half, y: r.midY - half, width: half*2, height: half*2)
        case .right:        return CGRect(x: r.maxX - half, y: r.midY - half, width: half*2, height: half*2)
        case .bottomLeft:   return CGRect(x: r.minX - half, y: r.minY - half, width: half*2, height: half*2)
        case .bottom:       return CGRect(x: r.midX - half, y: r.minY - half, width: half*2, height: half*2)
        case .bottomRight:  return CGRect(x: r.maxX - half, y: r.minY - half, width: half*2, height: half*2)
        }
    }
}

// MARK: - 选区绘制视图

private final class SelectionView: NSView {
    var onCommit: (CGRect?) -> Void = { _ in }
    var escMonitor: Any?

    fileprivate var state: SelectionState = .idle

    /// 当前选区的 rect（视图局部坐标，左下原点）
    private var selectionRect: CGRect?
    /// 创建选区时的起始/当前点
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    /// 移动/调整时的状态
    private var activeHandle: DragHandle?   // 正在调整哪个句柄
    private var moveOffset: NSPoint?        // 正在移动时的偏移基准

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // MARK: - Actions

    func cancel() {
        selectionRect = nil
        state = .idle
        dragStart = nil; dragCurrent = nil
        activeHandle = nil; moveOffset = nil
        needsDisplay = true
        onCommit(nil)
    }

    func confirm() {
        guard let r = selectionRect else { return }
        if r.width < 3 || r.height < 3 { cancel(); return }
        onCommit(r)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()

        // 半透明暗色遮罩（整屏）
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(bounds)

        if let rect = currentRect() {
            // 挖空选区
            context.setBlendMode(.destinationOut)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.setBlendMode(.normal)

            // 边框和阴影描边
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.5)

            // 外发光效果：两层边框
            context.saveGState()
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(3)
            context.stroke(rect.insetBy(dx: -1, dy: -1))
            context.restoreGState()

            context.stroke(rect)

            // 已确认选区：绘制调整句柄 + 尺寸标注
            if state == .selected, let sr = selectionRect {
                drawHandles(context, rect: sr)
                drawDimensionLabel(context, rect: sr)
            } else if state == .selecting {
                // 拖动中只显示尺寸
                drawDimensionLabel(context, rect: rect)
            }
        }

        context.restoreGState()
    }

    private func drawHandles(_ context: CGContext, rect: CGRect) {
        let fillColor = NSColor.white.cgColor
        let strokeColor = NSColor.black.withAlphaComponent(0.5).cgColor
        for handle in DragHandle.allCases {
            let r = handle.rect(in: rect)
            context.setFillColor(fillColor)
            context.fill(r)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(1)
            context.stroke(r)
        }
    }

    private func drawDimensionLabel(_ context: CGContext, rect: CGRect) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 6
        let labelW = size.width + padding * 2
        let labelH = size.height + padding * 2

        // 标注显示在选区正上方或正下方
        let below = rect.minY - 8 - labelH
        let above = rect.maxY + 8
        // 优先显示在上方（frame 内有足够空间）
        let labelRect: CGRect
        if above + labelH + 8 <= bounds.height {
            labelRect = CGRect(x: rect.midX - labelW / 2, y: above, width: labelW, height: labelH)
        } else if below >= 0 {
            labelRect = CGRect(x: rect.midX - labelW / 2, y: below, width: labelW, height: labelH)
        } else {
            labelRect = CGRect(x: rect.minX, y: rect.minY, width: labelW, height: labelH)
        }

        // 背景
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        let bgPath = CGPath(roundedRect: labelRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(bgPath)
        context.fillPath()

        // 文字
        let tx = labelRect.origin.x + padding
        let ty = labelRect.origin.y + padding
        (label as NSString).draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
    }

    // MARK: - 当前选区

    /// 返回当前实际选区（view 局部坐标，左下原点）
    private func currentRect() -> CGRect? {
        if let sr = selectionRect { return sr }
        if let start = dragStart, let current = dragCurrent {
            return normalizedRect(from: start, to: current)
        }
        return nil
    }

    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let pt = event.locationInWindow

        if state == .selected, let sr = selectionRect {
            // 检查是否点击了调整句柄
            for handle in DragHandle.allCases {
                if handle.rect(in: sr).insetBy(dx: -4, dy: -4).contains(pt) {
                    activeHandle = handle
                    dragStart = pt
                    dragCurrent = pt
                    return
                }
            }
            // 点击了内部 → 开始移动
            if sr.contains(pt) {
                moveOffset = NSPoint(x: pt.x - sr.origin.x, y: pt.y - sr.origin.y)
                return
            }
            // 点击了外部 → 重新开始选择
            state = .selecting
            selectionRect = nil
            dragStart = pt
            dragCurrent = pt
            needsDisplay = true
            return
        }

        // idle → 开始拖选
        state = .selecting
        dragStart = pt
        dragCurrent = pt
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = event.locationInWindow

        if let handle = activeHandle, var sr = selectionRect {
            let delta = CGSize(width: pt.x - (dragCurrent?.x ?? pt.x),
                               height: pt.y - (dragCurrent?.y ?? pt.y))
            sr = handle.adjust(rect: sr, by: delta)
            selectionRect = sr
            dragCurrent = pt
            needsDisplay = true
            // 更新光标
            handle.cursor.set()
            return
        }

        if let offset = moveOffset, var sr = selectionRect {
            var newOrigin = NSPoint(x: pt.x - offset.x, y: pt.y - offset.y)
            // 约束到 bounds
            newOrigin.x = max(0, min(bounds.width - sr.width, newOrigin.x))
            newOrigin.y = max(0, min(bounds.height - sr.height, newOrigin.y))
            sr.origin = newOrigin
            selectionRect = sr
            needsDisplay = true
            return
        }

        if state == .selecting {
            dragCurrent = pt
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            activeHandle = nil
            moveOffset = nil
            if state != .selected {
                dragStart = nil
                dragCurrent = nil
            }
        }

        if let handle = activeHandle {
            activeHandle = nil
            needsDisplay = true
            return
        }

        if moveOffset != nil {
            moveOffset = nil
            needsDisplay = true
            return
        }

        if state == .selecting {
            guard let s = dragStart, let c = dragCurrent else { return }
            let rect = normalizedRect(from: s, to: c)
            if rect.width < 3 || rect.height < 3 {
                state = .idle
                needsDisplay = true
                return
            }
            // 选区完成 → 进入 selected 状态
            selectionRect = rect
            state = .selected
            needsDisplay = true
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        if state == .selected, let sr = selectionRect {
            // 句柄区域设置光标
            for handle in DragHandle.allCases {
                addCursorRect(handle.rect(in: sr).insetBy(dx: -4, dy: -4), cursor: handle.cursor)
            }
            // 内部是移动光标
            addCursorRect(sr.insetBy(dx: 8, dy: 8), cursor: .openHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // 清除旧 tracking areas，添加新的
        trackingAreas.forEach { removeTrackingArea($0) }
        if state == .selected, let sr = selectionRect {
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate]
            let area = NSTrackingArea(rect: sr, options: options, owner: self)
            addTrackingArea(area)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            cancel()
        case 36, 76: // Return / Enter
            if state == .selected { confirm() }
        default:
            super.keyDown(with: event)
        }
    }
}
