import AppKit

/// 标注统一协议。所有几何坐标均在「图像坐标系」（原点左上、y 向下、单位 = 图像点）。
/// 画布负责把图像坐标转换为视图坐标后再绘制。
/// 值类型协议：各标注为 struct，画布以 `any Annotation` 存在性容器持有。
protocol Annotation {
    var id: UUID { get }
    /// 在上下文中绘制（toView 把图像坐标映射到视图坐标）。
    func draw(in ctx: CGContext, toView: (NSPoint) -> NSPoint, scale: CGFloat)
    /// 点是否命中（point 为图像坐标）。
    func contains(_ point: NSPoint) -> Bool
    /// 返回按 delta（图像坐标）平移后的副本。
    func translated(by delta: NSPoint) -> Annotation
    /// 图像坐标系下的包围盒（用于选中框与命中）。
    var boundingRect: NSRect { get }
    func withColor(_ color: NSColor) -> Annotation
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation
    func withFontSize(_ fontSize: CGFloat) -> Annotation
}

extension Annotation {
    func withFontSize(_ fontSize: CGFloat) -> Annotation { self }
}

/// 默认调色板（PixPin 风格）。
struct AnnotationPalette {
    static let colors: [NSColor] = [
        .red, .systemOrange, .yellow, .systemGreen, .systemBlue,
        .systemPurple, .systemPink, .white, .black, .systemTeal
    ]
    static let `default` = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
}

// MARK: - 工具

private let strokeHitTolerance: CGFloat = 8

private func strokedPathContains(_ path: CGPath, point: NSPoint, lineWidth: CGFloat) -> Bool {
    let width = max(strokeHitTolerance, lineWidth + 4)
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return stroked.contains(point)
}

private func distanceFrom(_ point: NSPoint, toSegmentFrom start: NSPoint, to end: NSPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(point.x - start.x, point.y - start.y) }
    let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / len2))
    let cx = start.x + t * dx
    let cy = start.y + t * dy
    return hypot(point.x - cx, point.y - cy)
}

// MARK: - 箭头

struct ArrowAnnotation: Annotation {
    let id = UUID()
    let start: NSPoint
    let end: NSPoint
    let color: NSColor
    let lineWidth: CGFloat

    var boundingRect: NSRect {
        NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -lineWidth * 6, dy: -lineWidth * 6)
    }

    func draw(in ctx: CGContext, toView: (NSPoint) -> NSPoint, scale: CGFloat) {
        let s = toView(start), e = toView(end)
        let lw = max(1, lineWidth * scale)
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 0 else { return }
        let ux = dx / len, uy = dy / len
        let px = -uy, py = ux
        let headLen = max(14, lw * 5)
        let headW = max(10, lw * 4)
        let baseX = e.x - ux * headLen, baseY = e.y - uy * headLen

        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: e.x, y: e.y))
        ctx.addLine(to: CGPoint(x: baseX + px * headW / 2, y: baseY + py * headW / 2))
        ctx.addLine(to: CGPoint(x: baseX - px * headW / 2, y: baseY - py * headW / 2))
        ctx.closePath()
        ctx.fillPath()

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: s.x, y: s.y))
        ctx.addLine(to: CGPoint(x: baseX, y: baseY))
        ctx.strokePath()
    }

    func contains(_ point: NSPoint) -> Bool {
        return distanceFrom(point, toSegmentFrom: start, to: end) <= lineWidth + strokeHitTolerance
    }

    func translated(by delta: NSPoint) -> Annotation {
        ArrowAnnotation(start: start + delta, end: end + delta, color: color, lineWidth: lineWidth)
    }
    func withColor(_ color: NSColor) -> Annotation { ArrowAnnotation(start: start, end: end, color: color, lineWidth: lineWidth) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { ArrowAnnotation(start: start, end: end, color: color, lineWidth: lineWidth) }
}

// MARK: - 矩形

struct RectAnnotation: Annotation {
    let id = UUID()
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat
    let filled: Bool

    var boundingRect: NSRect { rect }

    func draw(in ctx: CGContext, toView: (NSPoint) -> NSPoint, scale: CGFloat) {
        let r = toViewRect(toView)
        let lw = max(1, lineWidth * scale)
        if filled {
            ctx.setFillColor(color.withAlphaComponent(0.35).cgColor)
            ctx.fill(r)
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.stroke(r)
    }

    private func toViewRect(_ toView: (NSPoint) -> NSPoint) -> NSRect {
        let a = toView(rect.origin)
        let b = toView(NSPoint(x: rect.maxX, y: rect.maxY))
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func contains(_ point: NSPoint) -> Bool {
        if filled, rect.contains(point) { return true }
        let path = CGPath(rect: rect, transform: nil)
        return strokedPathContains(path, point: point, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        RectAnnotation(rect: rect.offsetBy(dx: delta.x, dy: delta.y), color: color, lineWidth: lineWidth, filled: filled)
    }
    func withColor(_ color: NSColor) -> Annotation { RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { RectAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled) }
}

// MARK: - 椭圆

struct EllipseAnnotation: Annotation {
    let id = UUID()
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat
    let filled: Bool

    var boundingRect: NSRect { rect }

    func draw(in ctx: CGContext, toView: (NSPoint) -> NSPoint, scale: CGFloat) {
        let r = toViewRect(toView)
        let lw = max(1, lineWidth * scale)
        if filled {
            ctx.setFillColor(color.withAlphaComponent(0.35).cgColor)
            ctx.fillEllipse(in: r)
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.strokeEllipse(in: r)
    }

    private func toViewRect(_ toView: (NSPoint) -> NSPoint) -> NSRect {
        let a = toView(rect.origin)
        let b = toView(NSPoint(x: rect.maxX, y: rect.maxY))
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func contains(_ point: NSPoint) -> Bool {
        let path = CGPath(ellipseIn: rect, transform: nil)
        if filled, path.contains(point) { return true }
        return strokedPathContains(path, point: point, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        EllipseAnnotation(rect: rect.offsetBy(dx: delta.x, dy: delta.y), color: color, lineWidth: lineWidth, filled: filled)
    }
    func withColor(_ color: NSColor) -> Annotation { EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { EllipseAnnotation(rect: rect, color: color, lineWidth: lineWidth, filled: filled) }
}

// MARK: - 文字

struct TextAnnotation: Annotation {
    let id = UUID()
    let origin: NSPoint
    var text: String
    let color: NSColor
    let fontSize: CGFloat

    var boundingRect: NSRect {
        let size = textSize()
        return NSRect(origin: origin, size: size)
    }

    private func textSize() -> NSSize {
        let attrs = textAttributes()
        let s = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: max(20, s.width), height: max(fontSize * 1.3, s.height))
    }

    private func textAttributes() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
         .foregroundColor: color]
    }

    func draw(in ctx: CGContext, toView: (NSPoint) -> NSPoint, scale: CGFloat) {
        let p = toView(origin)
        let attrs = textAttributes()
        (text as NSString).draw(at: p, withAttributes: attrs)
    }

    func contains(_ point: NSPoint) -> Bool {
        boundingRect.contains(point)
    }

    func translated(by delta: NSPoint) -> Annotation {
        TextAnnotation(origin: origin + delta, text: text, color: color, fontSize: fontSize)
    }
    func withColor(_ color: NSColor) -> Annotation { TextAnnotation(origin: origin, text: text, color: color, fontSize: fontSize) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }
    func withFontSize(_ fontSize: CGFloat) -> Annotation { TextAnnotation(origin: origin, text: text, color: color, fontSize: fontSize) }
}

// MARK: - 序号（编号气泡）

struct NumberedAnnotation: Annotation {
    let id = UUID()
    let center: NSPoint
    let number: Int
    let color: NSColor
    let radius: CGFloat

    var boundingRect: NSRect {
        NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    func draw(in ctx: CGContext, toView: (NSPoint) -> NSPoint, scale: CGFloat) {
        let c = toView(center)
        let r = radius * scale
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let label = "\(number)"
        let font = NSFont.boldSystemFont(ofSize: max(10, r * 1.1))
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        let p = NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        (label as NSString).draw(at: p, withAttributes: attrs)
    }

    func contains(_ point: NSPoint) -> Bool {
        hypot(point.x - center.x, point.y - center.y) <= radius + strokeHitTolerance
    }

    func translated(by delta: NSPoint) -> Annotation {
        NumberedAnnotation(center: center + delta, number: number, color: color, radius: radius)
    }
    func withColor(_ color: NSColor) -> Annotation { NumberedAnnotation(center: center, number: number, color: color, radius: radius) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }
    func withFontSize(_ fontSize: CGFloat) -> Annotation { self }
}

// MARK: - 马赛克

struct MosaicAnnotation: Annotation {
    let id = UUID()
    let rect: NSRect
    let pixelated: NSImage

    var boundingRect: NSRect { rect }

    func draw(in ctx: CGContext, toView: (NSPoint) -> NSPoint, scale: CGFloat) {
        let r = toViewRect(toView)
        pixelated.draw(in: r)
    }

    private func toViewRect(_ toView: (NSPoint) -> NSPoint) -> NSRect {
        let a = toView(rect.origin)
        let b = toView(NSPoint(x: rect.maxX, y: rect.maxY))
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func contains(_ point: NSPoint) -> Bool { rect.contains(point) }

    func translated(by delta: NSPoint) -> Annotation {
        MosaicAnnotation(rect: rect.offsetBy(dx: delta.x, dy: delta.y), pixelated: pixelated)
    }
    func withColor(_ color: NSColor) -> Annotation { self }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { self }
    func withFontSize(_ fontSize: CGFloat) -> Annotation { self }

    /// 从 base 图对应区域生成马赛克图。
    static func make(rect: NSRect, base: NSImage, block: CGFloat = 12) -> MosaicAnnotation {
        let safe = rect.integral.intersection(NSRect(origin: .zero, size: base.size))
        guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let sub = cg.cropping(to: safe) else {
            return MosaicAnnotation(rect: rect, pixelated: NSImage())
        }
        let small = NSSize(width: max(1, Int(safe.width / block)),
                           height: max(1, Int(safe.height / block)))
        let out = NSImage(size: safe.size)
        out.lockFocus()
        if let smallCG = resizeCG(sub, to: small) {
            let img = NSImage(cgImage: smallCG, size: safe.size)
            img.draw(in: NSRect(origin: .zero, size: safe.size),
                     from: .zero, operation: .copy, fraction: 1)
        }
        out.unlockFocus()
        return MosaicAnnotation(rect: rect, pixelated: out)
    }

    private static func resizeCG(_ src: CGImage, to size: NSSize) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return ctx.makeImage()
    }
}

// MARK: - 画笔（自由手绘）

struct PenAnnotation: Annotation {
    let id = UUID()
    let points: [NSPoint]
    let color: NSColor
    let lineWidth: CGFloat

    var boundingRect: NSRect {
        guard let a = points.first else { return .zero }
        var minX = a.x, minY = a.y, maxX = a.x, maxY = a.y
        for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }

    func draw(in ctx: CGContext, toView: (NSPoint) -> NSPoint, scale: CGFloat) {
        guard points.count > 1 else { return }
        let lw = max(1, lineWidth * scale)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        let first = toView(points[0])
        ctx.move(to: CGPoint(x: first.x, y: first.y))
        for p in points.dropFirst() {
            let v = toView(p)
            ctx.addLine(to: CGPoint(x: v.x, y: v.y))
        }
        ctx.strokePath()
    }

    func contains(_ point: NSPoint) -> Bool {
        for i in 0..<points.count - 1 {
            if distanceFrom(point, toSegmentFrom: points[i], to: points[i + 1]) <= lineWidth + strokeHitTolerance {
                return true
            }
        }
        return false
    }

    func translated(by delta: NSPoint) -> Annotation {
        PenAnnotation(points: points.map { $0 + delta }, color: color, lineWidth: lineWidth)
    }
    func withColor(_ color: NSColor) -> Annotation { PenAnnotation(points: points, color: color, lineWidth: lineWidth) }
    func withLineWidth(_ lineWidth: CGFloat) -> Annotation { PenAnnotation(points: points, color: color, lineWidth: lineWidth) }
}

// MARK: - 工具枚举

enum AnnotationTool: String, CaseIterable {
    case select, arrow, rect, ellipse, text, numbered, mosaic, pen, colorPick

    var title: String {
        switch self {
        case .select: return "选择"
        case .arrow: return "箭头"
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .numbered: return "序号"
        case .mosaic: return "马赛克"
        case .pen: return "画笔"
        case .colorPick: return "取色"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .arrow: return "arrow.up.right"
        case .rect: return "square"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .numbered: return "list.number"
        case .mosaic: return "checkerboard.rectangle"
        case .pen: return "pencil"
        case .colorPick: return "drop.fill"
        }
    }
}

private func +(lhs: NSPoint, rhs: NSPoint) -> NSPoint { NSPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
