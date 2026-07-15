import AppKit
import Foundation

/// 半透明全屏选区覆盖层：用户拖拽选择矩形区域，回调 NSScreen 坐标系（左下原点）的 CGRect。
/// 基于 AppKit NSPanel + NSView 实现，跨多显示器工作；Esc 或误点击取消。
@MainActor
final class RegionSelector {

    /// 开始选区。completion 返回选中的 rect（NSScreen 坐标）或 nil（取消）。
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
            if let localRect {
                // 局部坐标 -> 全局 NSScreen 坐标（左下原点）
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
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 选区绘制视图（AppKit 事件在主线程回调）
final class SelectionView: NSView {
    var onCommit: (CGRect?) -> Void = { _ in }
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // 半透明暗色遮罩（整屏）
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(bounds)
        // 挖空选区
        if let start, let current {
            let rect = normalizedRect(from: start, to: current)
            context.setBlendMode(.destinationOut)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.setBlendMode(.normal)
            // 边框
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect)
            // 尺寸标注
            let label = "\(Int(rect.width)) × \(Int(rect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            let tx = rect.origin.x + rect.width / 2 - size.width / 2
            let ty = rect.origin.y + rect.height + 8
            (label as NSString).draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
        }
        context.restoreGState()
    }

    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil }
        guard let s = start, let c = current else { onCommit(nil); return }
        let rect = normalizedRect(from: s, to: c)
        if rect.width < 3 || rect.height < 3 {
            onCommit(nil)   // 误点击视为取消
            return
        }
        onCommit(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            start = nil; current = nil
            onCommit(nil)
        }
    }
}
