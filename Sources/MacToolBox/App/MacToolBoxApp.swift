import SwiftUI
import AppKit

/// MacToolBox 应用入口
///
/// 双形态 App：
///   1. 启动时显示主窗口（标准 macOS 窗口，可在 Dock 看到图标）
///   2. 同时菜单栏常驻一个 status item（工具箱图标），左键弹功能面板
///   3. 面板含全部功能（系统/磁盘/Metal/启动），无底部栏；面板内「显示主窗口」可打开完整窗口
///   4. 主窗口底部「退出到菜单栏」收起窗口，并切换为 .accessory 模式：Dock 图标消失，仅保留右上角菜单栏
///   5. 从菜单栏「显示主窗口」切回 .regular 模式，Dock 图标恢复；右键状态栏图标弹出菜单（显示主窗口 / 退出 MacToolBox）
@main
struct MacToolBoxApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            // 注意：在 main() 里 setActivationPolicy 可能失败，统一在 delegate 中设置
            app.run()
        }
    }
}
