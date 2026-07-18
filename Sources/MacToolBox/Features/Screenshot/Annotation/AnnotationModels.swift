import AppKit

// MARK: - 标注工具类型（对应 macOS Markup Toolbar）

enum AnnotationTool: String, CaseIterable {
    case rectangle = "矩形框"
    case ellipse   = "圆形"
    case arrow     = "箭头"
    case pen       = "画笔"
    case text      = "文字"

    var icon: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.up.right"
        case .pen:       return "pencil"
        case .text:      return "textformat"
        }
    }
}

// MARK: - 预设颜色（对标 macOS 标注调色板）

struct AnnotationColor {
    let nsColor: NSColor
    let name: String

    static let red     = AnnotationColor(nsColor: NSColor(red: 1.0, green: 0.231, blue: 0.188, alpha: 1), name: "红")
    static let orange  = AnnotationColor(nsColor: NSColor(red: 1.0, green: 0.584, blue: 0.0,   alpha: 1), name: "橙")
    static let yellow  = AnnotationColor(nsColor: NSColor(red: 1.0, green: 0.796, blue: 0.0,   alpha: 1), name: "黄")
    static let green   = AnnotationColor(nsColor: NSColor(red: 0.204, green: 0.784, blue: 0.349, alpha: 1), name: "绿")
    static let blue    = AnnotationColor(nsColor: NSColor(red: 0.0,  green: 0.478, blue: 1.0,   alpha: 1), name: "蓝")
    static let purple  = AnnotationColor(nsColor: NSColor(red: 0.686, green: 0.322, blue: 0.871, alpha: 1), name: "紫")
    static let white   = AnnotationColor(nsColor: NSColor.white, name: "白")

    static let defaults: [AnnotationColor] = [red, orange, yellow, green, blue, purple]
}

// MARK: - 标注形状数据模型

/// 每一笔标注的不可变记录。draw(in:) 负责渲染到 CGContext。
enum AnnotationShape: Sendable {
    case rect(rect: NSRect, lineWidth: CGFloat, color: NSColor)
    case ellipse(rect: NSRect, lineWidth: CGFloat, color: NSColor)
    case arrow(from: NSPoint, to: NSPoint, lineWidth: CGFloat, color: NSColor)
    case pen(points: [NSPoint], lineWidth: CGFloat, color: NSColor)
    case text(string: String, origin: NSPoint, color: NSColor, fontSize: CGFloat)
    case mosaic(rect: NSRect)

    /// 绘制到 CGContext（已设置好坐标系）。
    func draw(in ctx: CGContext) {
        switch self {
        case let .rect(rect, lw, color):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lw)
            ctx.stroke(rect.insetBy(dx: lw / 2, dy: lw / 2))

        case let .ellipse(rect, lw, color):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lw)
            ctx.strokeEllipse(in: rect.insetBy(dx: lw / 2, dy: lw / 2))

        case let .arrow(from: start, to: end, lw, color):
            drawArrow(from: start, to: end, lineWidth: lw, color: color, in: ctx)

        case let .pen(points, lw, color):
            guard points.count >= 2 else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: points[0])
            for i in 1..<points.count {
                ctx.addLine(to: points[i])
            }
            ctx.strokePath()

        case let .text(str, origin, color, size):
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attr))
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            ctx.saveGState()
            // 画布是翻转坐标系（y 向下），Core Text 默认 y 向上 → 翻转 text matrix 使文字正向
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            // baseline 在 origin 下方 ascent 处（y 向下 = 更大的 y）；文字顶部对齐 origin
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y + ascent)
            CTLineDraw(line, ctx)
            ctx.restoreGState()

        case let .mosaic(rect):
            // 马赛克：将区域像素化（在画布上绘制模糊色块网格）
            drawMosaic(rect: rect, in: ctx)
        }
    }

    // MARK: - 箭头绘制

    private func drawArrow(from start: NSPoint, to end: NSPoint,
                           lineWidth lw: CGFloat, color: NSColor,
                           in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 线段
        let startPt = CGPoint(x: start.x, y: start.y)
        let endPt = CGPoint(x: end.x, y: end.y)
        ctx.move(to: startPt)
        ctx.addLine(to: endPt)
        ctx.strokePath()

        // 箭头头部
        let len = hypot(end.x - start.x, end.y - start.y)
        guard len > 1 else { ctx.restoreGState(); return }

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = max(12, lw * 5)
        let headAngle = CGFloat.pi / 5

        let p1 = CGPoint(
            x: end.x - headLen * cos(angle - headAngle),
            y: end.y - headLen * sin(angle - headAngle)
        )
        let p2 = CGPoint(
            x: end.x - headLen * cos(angle + headAngle),
            y: end.y - headLen * sin(angle + headAngle)
        )

        ctx.move(to: endPt)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()

        ctx.restoreGState()
    }

    // MARK: - 马赛克绘制

    private func drawMosaic(rect: NSRect, in ctx: CGContext) {
        let gridSize: CGFloat = 10
        guard rect.width > gridSize && rect.height > gridSize else { return }

        let cols = Int(rect.width / gridSize)
        let rows = Int(rect.height / gridSize)

        for r in 0..<rows {
            for c in 0..<cols {
                let cell = CGRect(
                    x: rect.minX + CGFloat(c) * gridSize,
                    y: rect.minY + CGFloat(r) * gridSize,
                    width: gridSize,
                    height: gridSize
                )
                // 取中心点颜色近似
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.fill(cell)
            }
        }
    }
}
