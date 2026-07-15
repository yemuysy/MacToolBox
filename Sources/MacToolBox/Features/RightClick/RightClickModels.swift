import Foundation

/// 右键增强的持久化配置（主程序侧）。
/// 由 `RightClickService` 持久化到 ConfigStore，并映射为 `RCMenuConfig` 推送给扩展。
struct RightClickConfig: Codable, Sendable {
    var enabled: Bool = false
    var showNewFile: Bool = true
    var showCopyPath: Bool = true
    var showOpenWith: Bool = true
    var showDelete: Bool = true
    var showToggleHidden: Bool = true
    var showCommonDirs: Bool = true
    var newFileTypes: [String] = ["txt", "md", "json", "csv"]
    var openWithApps: [RCOpenWithApp] = []
    var commonDirs: [RCCommonDir] = []
}
