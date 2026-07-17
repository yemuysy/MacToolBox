import AppKit
import CoreGraphics

/// 单个被检测到的窗口（CG 坐标系：原点在 primary 屏左上角，y 向下）。
struct DetectedWindow {
    let name: String
    let windowID: CGWindowID
    let layer: Int
    let frame: CGRect
}

/// 屏幕窗口检测器：用于截图时鼠标悬停高亮、单击直接捕获该窗口。
/// 借鉴 capcap 的 WindowDetector，做了清理与坐标说明。
final class WindowDetector {
    private var windows: [DetectedWindow] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// 最小面积阈值：小于此值的窗口视为装饰性子窗（工具栏/标题栏拆分等），不作为候选。
    private let minArea: CGFloat = 40000   // ≈ 200×200，排除过小的装饰元素

    /// 刷新当前可见窗口列表（排除本 App 自身的高层级弹窗与过小装饰子窗）。
    func refresh() {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            windows = []
            return
        }

        let primaryFrame = NSScreen.screens[0].frame
        let screenArea = primaryFrame.width * primaryFrame.height

        windows = infoList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsNS = info[kCGWindowBounds as String] as? NSDictionary,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer >= 0
            else { return nil }

            // 排除本 App 自己的屏幕级弹窗（toast/tooltip 等）
            if pid == ownPID && layer >= Int(CGWindowLevelForKey(.screenSaverWindow)) {
                return nil
            }
            // 跳过完全透明的不可见浮层
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                return nil
            }

            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsNS as CFDictionary, &rect) else { return nil }
            guard rect.width > 1, rect.height > 1 else { return nil }

            // 过小面积：标题栏/工具栏等拆分子窗，不是完整应用窗口
            if rect.width * rect.height < minArea {
                return nil
            }

            // 高层级系统浮层（输入法背景等）若接近全屏则跳过
            if layer >= 20, rect.width * rect.height > screenArea * 0.8 {
                return nil
            }

            let name = info[kCGWindowOwnerName as String] as? String ?? ""
            let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            return DetectedWindow(name: name, windowID: windowID, layer: layer, frame: rect)
        }
    }

    /// 返回包含 `cgPoint` 的**最外层完整窗口**（面积最大者）。
    ///
    /// CGWindowListCopyWindowInfo 对同一个 App 窗口常返回多条记录（标题栏、内容区、
    /// 工具栏等子窗），用 `first` 会拿到内部小窗导致高亮框只包住部分区域。
    /// 选面积最大的匹配窗口即可得到完整外框。
    func windowAt(cgPoint: CGPoint) -> DetectedWindow? {
        windows.filter { $0.frame.contains(cgPoint) }
              .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }
}
