import AppKit
import Foundation

/// 应用启动监听服务
///
/// 监听 NSWorkspace.didLaunchApplicationNotification，每次任意应用启动时
/// 捕获 PID、路径、参数（通过 ps -o args=）。
final class AppLaunchMonitorService: ObservableObject, @unchecked Sendable {
    static let shared = AppLaunchMonitorService()

    @Published private(set) var records: [AppLaunchRecord] = []

    private let maxRecords = 100
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        Logger.shared.info("AppLaunchMonitorService started")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        isRunning = false
    }

    func clear() {
        DispatchQueue.main.async {
            self.records.removeAll()
        }
    }

    // MARK: - Notification handler

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        let pid = app.processIdentifier
        guard pid > 0 else { return }

        let bundleId = app.bundleIdentifier
        let name = app.localizedName ?? "(unknown)"
        let bundleURL = app.bundleURL
        let executablePath = app.executableURL?.path
        let pidStr = String(pid)

        // 用 ps 读取参数：子进程调用放到后台队列，避免阻塞主线程（通知在主线程派发）
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let argsResult = ShellExecutor.run("/bin/ps", arguments: ["-o", "command=", "-p", pidStr])
            let arguments = Self.parseArguments(argsResult.stdout)

            let record = AppLaunchRecord(
                pid: pid,
                bundleIdentifier: bundleId,
                appName: name,
                bundleURL: bundleURL,
                executablePath: executablePath,
                arguments: arguments
            )

            Logger.shared.info("App launched: \(name) (pid=\(pid), args=\(arguments.count))")

            DispatchQueue.main.async {
                self?.records.insert(record, at: 0)
                if (self?.records.count ?? 0) > (self?.maxRecords ?? 100) {
                    self?.records.removeLast()
                }
            }
        }
    }

    // MARK: - Parsing

    /// 解析 ps -o command= 的输出，按空白切分
    private static func parseArguments(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 简单按空白分割，ps 输出已经丢失原本的引号信息
        return trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
