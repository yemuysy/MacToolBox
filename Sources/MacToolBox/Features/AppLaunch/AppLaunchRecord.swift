import Foundation

/// 一条应用启动记录，由 AppLaunchMonitorService 产生
struct AppLaunchRecord: Identifiable, Equatable {
    let id: UUID
    let pid: Int32
    let bundleIdentifier: String?
    let appName: String
    let bundleURL: URL?
    let executablePath: String?
    let arguments: [String]
    let launchedAt: Date

    init(
        pid: Int32,
        bundleIdentifier: String?,
        appName: String,
        bundleURL: URL?,
        executablePath: String?,
        arguments: [String],
        launchedAt: Date = Date()
    ) {
        self.id = UUID()
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.bundleURL = bundleURL
        self.executablePath = executablePath
        self.arguments = arguments
        self.launchedAt = launchedAt
    }
}
