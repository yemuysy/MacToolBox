import AppKit
import Foundation

/// 截图模式
enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case full, region, window
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full:   return "全屏"
        case .region: return "区域"
        case .window: return "窗口"
        }
    }
}

/// 截图引擎。
/// 设计原则：纯几何/文件名/PNG 编码为静态纯函数（可在沙盒测试中验证，无副作用）；
/// 实际捕获基于系统 `screencapture`（正确处理多屏、菜单栏、窗口阴影），仅在真实 App 主线程调用。
///
/// 捕获流程：先截到临时 PNG（`CapturedShot`），再由预览面板决定「保存到文件 / 复制到剪贴板 / 在访达显示」，
/// 不再在引擎内部静默落盘，给用户在截图后选择保存方式的机会。
struct ScreenshotEngine {

    // MARK: - 纯函数（可单测，无副作用、无 AppKit 依赖）

    /// 把选区约束到 bounds 内（标准几何，不依赖任何坐标系）
    static func clampRegion(_ region: CGRect, in bounds: CGRect) -> CGRect {
        guard !bounds.isEmpty else { return region }
        let x = min(max(region.origin.x, bounds.origin.x), bounds.maxX - 1)
        let y = min(max(region.origin.y, bounds.origin.y), bounds.maxY - 1)
        let w = min(max(region.width, 1), bounds.maxX - x)
        let h = min(max(region.height, 1), bounds.maxY - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 生成文件名：MacToolBox-20260715-143005.png
    static func buildFilename(date: Date = Date(), ext: String = "png") -> String {
        return "MacToolBox-\(Self.filenameFormatter.string(from: date)).\(ext)"
    }

    /// 文件名日期格式器（静态缓存，避免每次截图新建 DateFormatter）
    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 把 CGImage 编码为 PNG Data（测试时可注入任意 CGImage）
    static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 坐标系转换（AppKit，主线程）

    /// 把 NSScreen 坐标（左下原点，y 向上）的 rect 转为 screencapture -R 坐标（左上原点，y 向下）
    @MainActor
    static func toScreencaptureRect(_ rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        let global = screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !global.isEmpty else { return rect }
        let x = rect.minX - global.minX
        let y = global.maxY - rect.maxY
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    // MARK: - 实际捕获（@MainActor，真实 App 调用）

    /// 一次捕获的结果：原始图像 + 临时 PNG 路径。
    /// 预览 / 保存到文件 / 复制到剪贴板都基于它，关闭后由 `cleanup(_:)` 删除临时文件。
    struct CapturedShot {
        let image: NSImage
        let tempURL: URL
    }

    @MainActor
    static func capture(
        _ mode: CaptureMode,
        region: CGRect? = nil
    ) -> Result<CapturedShot, Error> {
        // 预先检查屏幕录制权限
        guard checkScreenRecordingPermission() else {
            return .failure(ScreenshotError.noPermission)
        }

        var args: [String] = []
        switch mode {
        case .full:
            let global = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            let sc = toScreencaptureRect(global)
            args = ["-R", "\(Int(sc.origin.x)),\(Int(sc.origin.y)),\(Int(sc.width)),\(Int(sc.height))"]
        case .region:
            guard let region else { return .failure(ScreenshotError.invalidRegion) }
            let sc = toScreencaptureRect(region)
            args = ["-R", "\(Int(sc.origin.x)),\(Int(sc.origin.y)),\(Int(sc.width)),\(Int(sc.height))"]
        case .window:
            args = ["-w"]   // 捕获当前最前面的窗口（非交互）
        }

        return runScreencapture(arguments: args)
    }

    /// 检查当前进程是否有屏幕录制权限（通过尝试创建 CGDisplayStream 判断）。
    /// - Returns: `true` 有权限，`false` 无权限。
    static func checkScreenRecordingPermission() -> Bool {
        // CGDisplayStream 在有权限时返回非 nil，无权限时返回 nil
        let stream = CGDisplayStream(
            dispatchQueueDisplay: CGMainDisplayID(),
            outputWidth: 1,
            outputHeight: 1,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: nil,
            queue: DispatchQueue.global(),
            handler: { _, _, _, _ in }
        )
        return stream != nil
    }

    @MainActor
    private static func runScreencapture(arguments: [String]) -> Result<CapturedShot, Error> {
        // 总是先截到临时文件，保存/复制/预览交给调用方决定
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let (_, stderr, code) = ShellExecutor.run("/usr/sbin/screencapture",
                                                  arguments: arguments + ["-x", tmp.path])
        guard code == 0 else {
            return .failure(ScreenshotError.captureFailed(stderr))
        }
        guard let data = try? Data(contentsOf: tmp),
              let image = NSImage(data: data) else {
            return .failure(ScreenshotError.decodeFailed)
        }
        return .success(CapturedShot(image: image, tempURL: tmp))
    }

    // MARK: - 保存 / 复制 / 清理

    /// 把一次捕获保存到指定文件（复制临时 PNG 到目标路径，目标已存在则覆盖）。
    static func save(_ shot: CapturedShot, to url: URL) -> Bool {
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.copyItem(at: shot.tempURL, to: url)
            return true
        } catch {
            return false
        }
    }

    /// 把一次捕获写入系统剪贴板（PNG + TIFF + NSImage 三种形式，最大化兼容「粘贴」）。
    static func writeToClipboard(_ shot: CapturedShot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = try? Data(contentsOf: shot.tempURL) {
            pb.setData(data, forType: .png)
        }
        if let tiff = shot.image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([shot.image])
    }

    /// 清理临时文件（保存完成或关闭预览时调用）。
    static func cleanup(_ shot: CapturedShot) {
        try? FileManager.default.removeItem(at: shot.tempURL)
    }

    enum ScreenshotError: LocalizedError {
        case invalidRegion
        case captureFailed(String)
        case clipboardFailed
        case decodeFailed
        case noPermission
        var errorDescription: String? {
            switch self {
            case .invalidRegion:       return "选区无效"
            case .captureFailed(let s): return "截图失败：\(s)"
            case .clipboardFailed:     return "写入剪贴板失败"
            case .decodeFailed:        return "截图数据解码失败"
            case .noPermission:        return "无屏幕录制权限"
            }
        }
    }
}
