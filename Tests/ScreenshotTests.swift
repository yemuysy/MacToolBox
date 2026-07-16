import Foundation
import AppKit
import CoreGraphics

/// 新版截图模块纯逻辑测试（标注模型 / 模式枚举 / 几何 / 调色板；不涉及 UI 或屏幕）。
enum ScreenshotTests {
    static func run() {
        print("Screenshot:")
        testCaptureMode()
        testAnnotationTools()
        testMath()
        testAnnotations()
        testPalette()
    }

    private static func testCaptureMode() {
        let all = CaptureMode.allCases
        check(all.count == 3, "CaptureMode 含 3 种模式")
        let titles = all.map { $0.title }
        check(titles.allSatisfy { !$0.isEmpty }, "CaptureMode 标题非空：\(titles.joined(separator: "/"))")
        check(CaptureMode.region.id == "region", "CaptureMode.region id")
    }

    private static func testAnnotationTools() {
        let all = AnnotationTool.allCases
        check(all.count == 9, "AnnotationTool 含 9 个工具")
        check(all.allSatisfy { !$0.symbol.isEmpty && !$0.title.isEmpty },
              "AnnotationTool 图标/标题非空")
    }

    private static func testMath() {
        let b = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r1 = ScreenshotMath.clamp(CGRect(x: -10, y: -10, width: 50, height: 50), in: b)
        check(r1.origin.x == 0 && r1.origin.y == 0, "clamp 负坐标到边界")
        let r2 = ScreenshotMath.clamp(CGRect(x: 80, y: 80, width: 50, height: 50), in: b)
        check(r2.origin.x == 80 && r2.width == 20 && r2.height == 20, "clamp 超出宽度截断")
        let r3 = ScreenshotMath.clamp(CGRect(x: 10, y: 10, width: 0, height: 0), in: b)
        check(r3.width == 1 && r3.height == 1, "clamp 零尺寸到最小 1x1")
    }

    private static func testAnnotations() {
        // 矩形命中（非填充：仅边线附近命中）
        let rect = RectAnnotation(rect: NSRect(x: 0, y: 0, width: 50, height: 20),
                                   color: .red, lineWidth: 4, filled: false)
        check(rect.contains(NSPoint(x: 25, y: 1)), "矩形边线命中")
        check(!rect.contains(NSPoint(x: 25, y: 15)), "矩形内部（非填充）不命中")
        check(rect.boundingRect == NSRect(x: 0, y: 0, width: 50, height: 20), "矩形包围盒")

        // 箭头命中（靠近线段）
        let arr = ArrowAnnotation(start: NSPoint(x: 0, y: 0), end: NSPoint(x: 100, y: 0),
                                  color: .red, lineWidth: 4)
        check(arr.contains(NSPoint(x: 50, y: 1)), "箭头线段附近命中")
        check(!arr.contains(NSPoint(x: 50, y: 40)), "箭头远离不命中")

        // 序号气泡命中
        let num = NumberedAnnotation(center: NSPoint(x: 30, y: 30), number: 1, color: .red, radius: 14)
        check(num.contains(NSPoint(x: 30, y: 30)), "序号中心命中")
        check(!num.contains(NSPoint(x: 60, y: 60)), "序号远点不命中")

        // 文字包围盒
        let txt = TextAnnotation(origin: NSPoint(x: 5, y: 5), text: "Hi", color: .red, fontSize: 20)
        check(txt.boundingRect.contains(NSPoint(x: 6, y: 6)), "文字原点命中")

        // 马赛克几何（不触发 cgImage，避免无屏环境）
        let mos = MosaicAnnotation(rect: NSRect(x: 0, y: 0, width: 30, height: 30), pixelated: NSImage())
        check(mos.contains(NSPoint(x: 10, y: 10)) && !mos.contains(NSPoint(x: 40, y: 40)),
              "马赛克矩形命中")
    }

    private static func testPalette() {
        check(!AnnotationPalette.colors.isEmpty, "调色板非空")
        let d = AnnotationPalette.default
        check(d.redComponent > 0.9 && d.greenComponent < 0.4, "默认色为红系")
    }
}
