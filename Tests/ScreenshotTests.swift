import Foundation
import AppKit
import CoreGraphics

/// 新版截图模块纯逻辑测试（模式枚举 / 几何；不涉及 UI 或屏幕）。
enum ScreenshotTests {
    static func run() {
        print("Screenshot:")
        testCaptureMode()
        testMath()
    }

    private static func testCaptureMode() {
        let all = CaptureMode.allCases
        check(all.count == 3, "CaptureMode 含 3 种模式")
        let titles = all.map { $0.title }
        check(titles.allSatisfy { !$0.isEmpty }, "CaptureMode 标题非空：\(titles.joined(separator: "/"))")
        check(CaptureMode.region.id == "region", "CaptureMode.region id")
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
}
