import Foundation
import OSLog

/// 轻量日志器，使用 OSLog 后端，避免写文件 IO
final class Logger: @unchecked Sendable {
    static let shared = Logger()

    private let log = OSLog(subsystem: "com.yemu.mactoolbox", category: "app")

    private init() {}

    func info(_ message: String) { write(.info, message) }
    func warning(_ message: String) { write(.default, message) }
    func error(_ message: String) { write(.error, message) }

    private func write(_ type: OSLogType, _ message: String) {
        os_log("%{public}@", log: log, type: type, message)
    }
}
