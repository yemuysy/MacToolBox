import Foundation

/// 右键增强的持久化配置（主程序侧）。
/// 由 `RightClickService` 持久化到 ConfigStore，并映射为 `RCMenuConfig` 推送给扩展 / 写入 App Group 共享文件。
///
/// 动作集对标开源右键增强（RightKit / SaneClick / Flicker）：
/// 新建文件、从模板新建、复制路径、复制文件名、用 App 打开、在终端打开、在 Finder 显示、
/// 隐藏/显示、直接删除、常用目录。
struct RightClickConfig: Codable, Sendable {
    var enabled: Bool = false

    // 新建文件
    var showNewFile: Bool = true
    var newFileTypes: [String] = ["txt", "md", "json", "csv"]

    // 从模板新建（RightKit 标志性功能）
    var showNewFileFromTemplate: Bool = true
    var templateFolder: String? = nil        // 模板目录路径
    var templateFiles: [String] = []          // 模板文件名（主程序枚举后缓存，扩展仅展示）

    // 复制
    var showCopyPath: Bool = true
    var showCopyName: Bool = true

    // 打开
    var showOpenWith: Bool = true
    var showOpenInTerminal: Bool = true
    var terminalBundleID: String? = nil       // 终端 App bundleID（默认 nil = 系统 Terminal）
    var showRevealInFinder: Bool = true

    // 文件操作
    var showDelete: Bool = true
    var showToggleHidden: Bool = true

    // 常用目录
    var showCommonDirs: Bool = true
    var openWithApps: [RCOpenWithApp] = []
    var commonDirs: [RCCommonDir] = []
}
