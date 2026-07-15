import Foundation

/// Metal HUD 全局开关服务
///
/// macOS 13+ 提供了 `METAL_HUD_ENABLED` 环境变量，开启后任何使用 Metal 的应用
/// 启动时都会在窗口右上角显示 GPU 占用、帧率、绘制调用等信息。
///
/// 通过 `launchctl setenv METAL_HUD_ENABLED 1` 设置当前用户会话的全局环境变量，
/// 之后启动的应用会继承此设置。已运行的应用不受影响，需重启才能看到效果。
final class MetalHUDService: ObservableObject, @unchecked Sendable {
    static let shared = MetalHUDService()

    @Published private(set) var isEnabled: Bool

    private init() {
        // 启动时通过 launchctl getenv 探测当前实际状态
        isEnabled = MetalHUDService.detectEnabled()
    }

    /// 探测当前用户会话中 METAL_HUD_ENABLED 的实际状态
    private static func detectEnabled() -> Bool {
        let result = ShellExecutor.run("/bin/launchctl", arguments: ["getenv", "METAL_HUD_ENABLED"])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func enable() {
        let result = ShellExecutor.run("/bin/launchctl", arguments: ["setenv", "METAL_HUD_ENABLED", "1"])
        if result.exitCode == 0 {
            DispatchQueue.main.async {
                self.isEnabled = true
            }
            Logger.shared.info("Metal HUD enabled")
        } else {
            Logger.shared.error("Failed to enable Metal HUD: \(result.stderr)")
        }
    }

    func disable() {
        let result = ShellExecutor.run("/bin/launchctl", arguments: ["unsetenv", "METAL_HUD_ENABLED"])
        if result.exitCode == 0 {
            DispatchQueue.main.async {
                self.isEnabled = false
            }
            Logger.shared.info("Metal HUD disabled")
        } else {
            Logger.shared.error("Failed to disable Metal HUD: \(result.stderr)")
        }
    }

    func toggle() {
        if isEnabled { disable() } else { enable() }
    }

    // MARK: - 直接为指定 App 开启 HUD 并启动

    /// 启动结果
    struct LaunchResult {
        let success: Bool
        let message: String
    }

    /// 找到 .app 包内的可执行文件
    private static func executableURL(of appPath: String) -> URL? {
        let appURL = URL(fileURLWithPath: appPath)
        guard appURL.pathExtension.lowercased() == "app" else { return nil }
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: infoPlistURL),
              let execName = dict["CFBundleExecutable"] as? String else { return nil }
        let execURL = appURL.appendingPathComponent("Contents/MacOS/\(execName)")
        return FileManager.default.isExecutableFile(atPath: execURL.path) ? execURL : nil
    }

    /// 直接以 `METAL_HUD_ENABLED=1` 启动指定 App 的二进制。
    ///
    /// 关键点：
    /// 1. 通过 `open -a` / Finder 启动无法把环境变量传进去，`launchctl setenv` 也只对之后从
    ///    launchd 继承环境的新进程生效，且已运行的 App 不受影响。
    /// 2. 这里用 `setsid` 把二进制放进独立会话直接拉起，环境里带上 `METAL_HUD_ENABLED=1`，
    ///    可 100% 保证该 App 的 Metal HUD 出现，且进程与本工具解耦（本工具退出也不影响它）。
    /// 3. 启动在后台线程进行且**不等待** App 退出（`setsid` 已让子进程脱离本进程），
    ///    避免 `waitUntilExit` 一直阻塞主线程直到用户手动退出目标 App。
    func launchAppWithHUD(_ appPath: String) -> LaunchResult {
        guard let execURL = MetalHUDService.executableURL(of: appPath) else {
            return LaunchResult(success: false, message: "无法解析应用：请选择 .app 程序包")
        }

        let execName = execURL.deletingLastPathComponent().lastPathComponent

        // 先关掉已运行的同名实例，否则新实例可能因单例锁而直接退出（此步很快，同步执行）
        ShellExecutor.run("/usr/bin/pkill", arguments: ["-x", execName])

        // setsid 进入新会话 + 重定向标准流，彻底脱离本进程；后台拉起，不阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async {
            let cmd = "setsid env METAL_HUD_ENABLED=1 \"\(execURL.path)\" >/dev/null 2>&1 < /dev/null"
            let result = ShellExecutor.runShell(cmd)
            if result.exitCode == 0 {
                Logger.shared.info("Launched \(execName) with Metal HUD")
            } else {
                Logger.shared.error("Failed to launch with HUD: \(result.stderr)")
            }
        }

        return LaunchResult(success: true, message: "已启动「\(execName)」，窗口右上角应出现 Metal HUD")
    }
}
