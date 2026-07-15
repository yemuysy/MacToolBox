import Foundation
import CoreGraphics

/// ScreenshotEngine 纯函数测试（不依赖屏幕/沙盒）
enum ScreenshotEngineTests {
    static func run() {
        print("ScreenshotEngine:")
        let b = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r1 = ScreenshotEngine.clampRegion(CGRect(x: -10, y: -10, width: 50, height: 50), in: b)
        check(r1.origin.x == 0 && r1.origin.y == 0, "clamp 负坐标到边界")
        let r2 = ScreenshotEngine.clampRegion(CGRect(x: 80, y: 80, width: 50, height: 50), in: b)
        check(r2.origin.x == 80 && r2.width == 20 && r2.height == 20, "clamp 超出宽度截断")
        let r3 = ScreenshotEngine.clampRegion(CGRect(x: 10, y: 10, width: 0, height: 0), in: b)
        check(r3.width == 1 && r3.height == 1, "clamp 零尺寸到最小 1x1")

        let name = ScreenshotEngine.buildFilename(date: Date(timeIntervalSince1970: 0), ext: "png")
        check(name.hasPrefix("MacToolBox-19700101-") && name.hasSuffix(".png"), "buildFilename 格式: \(name)")

        if let img = makeTestImage(), let data = ScreenshotEngine.pngData(from: img) {
            check(data.count > 0, "pngData 编码 PNG 非空（\(data.count) bytes）")
        } else {
            check(false, "pngData 编码失败")
        }
    }

    private static func makeTestImage() -> CGImage? {
        let w = 8, h = 8
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
