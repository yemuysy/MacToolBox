import AppKit

/// 图标缓存：菜单栏与主窗口所需的位图图标只从磁盘加载一次，
/// 避免 SwiftUI 每帧重渲染时重复 `NSImage(contentsOfFile:)` 造成的 I/O 浪费。
enum IconCache {
    /// 主程序图标（AppIcon.icns）
    static let appIcon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns") else { return nil }
        return NSImage(contentsOfFile: path)
    }()

    /// 菜单栏状态栏图标（MenuBarIcon.png，彩色）
    static let menuBarIcon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }()
}
