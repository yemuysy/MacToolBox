import Foundation

/// 测试报告器（线程安全，供同步/异步测试共享）
final class TestState: @unchecked Sendable {
    static let shared = TestState()
    private let lock = NSLock()
    private(set) var failures = 0
    func record(_ ok: Bool, _ msg: String) {
        lock.lock()
        if ok { print("  ✓ \(msg)") } else { print("  ✗ \(msg)"); failures += 1 }
        lock.unlock()
    }
}

func check(_ ok: Bool, _ msg: String) { TestState.shared.record(ok, msg) }

@main
struct TestRunner {
    /// 使用 async main：直接 await actor 测试，避免在主线程用信号量阻塞导致的并发死锁。
    static func main() async {
        print("== MacToolBox 沙盒测试 ==")
        ScreenshotEngineTests.run()
        HotkeyTests.run()
        BrewServiceTests.run()
        LaunchAgentServiceTests.run()

        // 异步测试：DiskCleaner（actor）
        await DiskCleanerTests.run()

        print("")
        if TestState.shared.failures == 0 {
            print("✅ ALL TESTS PASSED")
        } else {
            print("❌ \(TestState.shared.failures) TEST(S) FAILED")
        }
        exit(TestState.shared.failures == 0 ? 0 : 1)
    }
}
