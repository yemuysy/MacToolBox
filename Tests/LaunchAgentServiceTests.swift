import Foundation

/// LaunchAgentService plist 解析测试
enum LaunchAgentServiceTests {
    static func run() {
        print("LaunchAgentService parsePlistFile:")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactoolbox_la_\(UUID().uuidString).plist")
        let dict: [String: Any] = [
            "Label": "com.test.demo",
            "ProgramArguments": ["/bin/echo", "hi"],
            "RunAtLoad": true
        ]
        (dict as NSDictionary).write(to: tmp, atomically: false)
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let item = LaunchAgentService.parsePlistFile(tmp, disabled: false) else {
            check(false, "解析返回 nil")
            return
        }
        check(item.label == "com.test.demo", "解析 Label")
        check(item.programArguments == ["/bin/echo", "hi"], "解析 ProgramArguments")
        check(item.runAtLoad == true, "解析 RunAtLoad")
        check(item.disabled == false, "disabled 标记正确")
    }
}
