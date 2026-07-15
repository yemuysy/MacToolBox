import SwiftUI

/// 轻量迷你折线图：纯 SwiftUI Path 自绘，不依赖 Charts。
/// 用于菜单栏面板里的实时趋势展示。
struct Sparkline: View {
    let values: [Double]
    let color: Color
    /// 固定量程上限；为 nil 时按数据最大值自动缩放
    var maxValue: Double? = nil
    /// 被视作「无效/不支持」的占位值（如 -1），绘制时跳过
    var invalidValue: Double = -1

    var body: some View {
        GeometryReader { geo in
            // 几何点只计算一次，供面积与折线共用，避免每帧重复枚举 60 个点
            let pts = points(in: geo.size)
            if pts.count >= 2 {
                ZStack(alignment: .bottom) {
                    areaPath(pts, baselineHeight: geo.size.height)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.28), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(pts)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Text("暂无数据")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - 几何计算

    private func validPoints() -> [(index: Int, value: Double)] {
        values.enumerated().compactMap { i, v in
            v == invalidValue ? nil : (i, v)
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let valid = validPoints()
        guard valid.count >= 2 else { return [] }
        let maxScale = (maxValue ?? valid.map { $0.value }.max() ?? 1)
        let scale = maxScale > 0 ? maxScale : 1
        let stepX = size.width / CGFloat(valid.count - 1)
        return valid.enumerated().map { (i, p) in
            let x = CGFloat(i) * stepX
            let ratio = min(1, max(0, p.value / scale))
            let y = size.height - ratio * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        guard pts.count >= 2 else { return Path() }
        var path = Path()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        return path
    }

    private func areaPath(_ pts: [CGPoint], baselineHeight: CGFloat) -> Path {
        guard let first = pts.first, let last = pts.last else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: first.x, y: baselineHeight))
        path.addLine(to: first)
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        path.addLine(to: CGPoint(x: last.x, y: baselineHeight))
        path.closeSubpath()
        return path
    }
}
