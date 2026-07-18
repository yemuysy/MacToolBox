import Foundation

/// 所有可选功能的唯一标识。
/// 新增功能只需在此追加 case，并在 `FeatureManager.buildDefinitions()` 中注册其视图与默认启用状态。
/// 侧边栏、内容区、菜单栏面板、快捷键全部以 FeatureID 驱动，实现「功能开关 → 主界面裁剪 → 省内存」。
enum FeatureID: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case diskMount
    case metalHUD
    case appLaunch
    case folderMap
    case brew
    case cleanup
    case launchAgent
    case screenshot
    case scrollControl
    case rightClick
    case hosts

    var id: String { rawValue }
}
