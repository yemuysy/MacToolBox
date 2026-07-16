import AppKit
import CoreGraphics

/// 截图模式（供 UI 与快捷键共用）。
enum CaptureMode: String, CaseIterable, Identifiable {
    case region, full, window
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: return "区域"
        case .full:   return "全屏"
        case .window: return "窗口"
        }
    }
}

/// 截图流程编排：把「捕获 → 标注编辑 / 贴图 / 直接保存」串起来，供快捷键与主界面调用。
///
/// 设计：捕获由 `CaptureSession`（基于 CGDisplayCreateImage，正确处理多屏与窗口吸附）完成；
/// 标注编辑由 `AnnotationEditorController` 完成；贴图由 `PinManager` 完成。
/// 本枚举只做编排，不触碰具体绘制逻辑。
enum ScreenshotFlow {
    /// 检查屏幕录制权限（CGDisplayStream 在有权限时非 nil）。
    static func checkPermission() -> Bool {
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

    /// 文件名：MacToolBox-20260715-143005.png
    static func buildFilename(ext: String = "png") -> String {
        "MacToolBox-\(filenameFormatter.string(from: Date())).\(ext)"
    }
    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 把 NSImage 编码为 PNG 保存到 url（覆盖已存在文件）。
    static func savePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true }
        catch { return false }
    }

    /// 统一入口。
    /// - mode: 捕获模式。
    /// - pin: true 时捕获后直接贴图，不进编辑器。
    /// - autoSaveDir: 非 nil 时捕获后直接保存到该目录（不进编辑器）。
    /// - onSaved: 直接保存成功后的回调（主线程）。
    @MainActor static func start(mode: CaptureMode, pin: Bool = false,
                     autoSaveDir: URL? = nil, onSaved: ((URL) -> Void)? = nil) {
        guard checkPermission() else {
            print("MacToolBox: 无屏幕录制权限，无法截图")
            return
        }
        CaptureSession.run(mode: mode, defaultSaveDir: autoSaveDir) { result in
            guard let result else { return }
            if pin {
                PinManager.shared.pin(result.image)
            } else if let dir = autoSaveDir {
                let url = dir.appendingPathComponent(Self.buildFilename())
                if savePNG(result.image, to: url) { onSaved?(url) }
            } else {
                AnnotationEditorController.edit(result.image)
            }
        }
    }
}

/// 截图相关纯几何（可单测，无副作用、无坐标系假设）。
enum ScreenshotMath {
    /// 把 region 约束到 bounds 内（最小 1×1）。
    static func clamp(_ region: CGRect, in bounds: CGRect) -> CGRect {
        guard !bounds.isEmpty else { return region }
        let x = min(max(region.origin.x, bounds.origin.x), bounds.maxX - 1)
        let y = min(max(region.origin.y, bounds.origin.y), bounds.maxY - 1)
        let w = min(max(region.width, 1), bounds.maxX - x)
        let h = min(max(region.height, 1), bounds.maxY - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
