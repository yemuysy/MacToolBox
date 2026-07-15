import Foundation

/// 包装 Process，方便执行 shell 命令并捕获输出
enum ShellExecutor {

    /// 执行命令，返回 (stdout, stderr, exitCode)
    @discardableResult
    static func run(
        _ command: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) -> (stdout: String, stderr: String, exitCode: Int) {
        let task = Process()
        task.launchPath = command
        task.arguments = arguments
        if let environment = environment {
            task.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()
        } catch {
            return ("", error.localizedDescription, -1)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (stdout, stderr, Int(task.terminationStatus))
    }

    /// 通过 /bin/sh -c 执行组合命令
    @discardableResult
    static func runShell(_ command: String) -> (stdout: String, stderr: String, exitCode: Int) {
        return run("/bin/sh", arguments: ["-c", command])
    }
}
