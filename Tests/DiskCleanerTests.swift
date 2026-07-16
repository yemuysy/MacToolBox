import Foundation

/// DiskCleaner 沙盒测试：扫描 / 删除 / 白名单保护 / 分类 / 分批
enum DiskCleanerTests {
    static func run() async {
        print("DiskCleaner:")

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [CleanupItem] = []
            func add(_ i: CleanupItem) { lock.lock(); items.append(i); lock.unlock() }
            var all: [CleanupItem] { lock.lock(); defer { lock.unlock() }; return items }
        }

        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacToolBoxTestSandbox")
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // 构造模拟目录：Caches、Logs、tmp
        let caches = base.appendingPathComponent("Library/Caches")
        let logs = base.appendingPathComponent("Library/Logs")
        let tmp = base.appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 应用缓存
        let appCacheDir = caches.appendingPathComponent("com.tencent.qq")
        try? FileManager.default.createDirectory(at: appCacheDir, withIntermediateDirectories: true)
        let f1 = appCacheDir.appendingPathComponent("cache1.bin")
        try? Data(count: 1024).write(to: f1)

        // 浏览器缓存
        let browserCacheDir = caches.appendingPathComponent("com.apple.Safari")
        try? FileManager.default.createDirectory(at: browserCacheDir, withIntermediateDirectories: true)
        let f2 = browserCacheDir.appendingPathComponent("webcache.db")
        try? "safari".write(to: f2, atomically: true, encoding: .utf8)

        // 日志
        let f3 = logs.appendingPathComponent("system.log")
        try? "log".write(to: f3, atomically: true, encoding: .utf8)

        // 临时文件
        let f4 = tmp.appendingPathComponent("temp.txt")
        try? "temp".write(to: f4, atomically: true, encoding: .utf8)

        // 白名单校验
        let cleaner = DiskCleaner(allowedRoots: [base])
        check(await cleaner.isAllowed(base), "白名单内根允许")
        check(!(await cleaner.isAllowed(URL(fileURLWithPath: "/System"))), "白名单外根拒绝")

        // 扫描测试
        let collector = Collector()
        let total = await cleaner.scan() { batch in
            for item in batch { collector.add(item) }
        }
        let allItems = collector.all
        check(allItems.contains(where: { $0.url == f1 }), "扫描包含应用缓存文件")
        check(allItems.contains(where: { $0.url == f2 }), "扫描包含浏览器缓存文件")
        check(allItems.contains(where: { $0.url == f3 }), "扫描包含日志文件")
        check(allItems.contains(where: { $0.url == f4 }), "扫描包含临时文件")
        check(total >= Int64(1024 + 6 + 3 + 4), "累计字节 >= 实际大小")

        // 分类规则测试
        let appItem = allItems.first { $0.url == f1 }
        check(appItem?.category == .application, "应用缓存归为 application (\(appItem?.category.rawValue ?? "nil"))")
        check(appItem?.appName == "QQ", "应用缓存识别为 QQ (\(appItem?.appName ?? ""))")
        check(appItem?.risk == .safe, "应用缓存风险 safe")

        let browserItem = allItems.first { $0.url == f2 }
        check(browserItem?.category == .internet, "浏览器缓存归为 internet (\(browserItem?.category.rawValue ?? "nil"))")
        check(browserItem?.appName == "Safari", "浏览器缓存识别为 Safari")

        let logItem = allItems.first { $0.url == f3 }
        check(logItem?.category == .system, "日志归为 system")
        check(logItem?.risk == .safe, "日志风险 safe")

        let tmpItem = allItems.first { $0.url == f4 }
        check(tmpItem?.category == .system, "临时文件归为 system")

        // CleanupClassifier 直接测试
        let directSystem = CleanupClassifier.classify(f3, parentRoot: logs)
        check(directSystem.category == .system, "classify 日志为 system")
        let directApp = CleanupClassifier.classify(f1, parentRoot: caches)
        check(directApp.category == .application, "classify 应用缓存为 application")
        let directInternet = CleanupClassifier.classify(f2, parentRoot: caches)
        check(directInternet.category == .internet, "classify 浏览器缓存为 internet")

        // 默认选择策略：safe 项应被选中（走真实 scan 流程，不直写内部状态）
        let selService = CleanupService(cleaner: DiskCleaner(allowedRoots: [base]))
        await selService.scan()
        let safeCount = allItems.filter { $0.risk == .safe }.count
        let defaultSel = await selService.defaultSelection()
        check(defaultSel.count == safeCount, "默认选择仅 safe 项 (\(defaultSel.count)/\(safeCount))")
        check(defaultSel.contains(f1), "safe 应用缓存默认被选中")
        check(defaultSel.contains(f2), "safe 浏览器缓存默认被选中")

        // 白名单内删除成功
        let failIn = await cleaner.delete(at: [f1])
        check(failIn.isEmpty, "白名单内删除无失败")
        check(!FileManager.default.fileExists(atPath: f1.path), "文件已被删除")

        // 分批删除测试：创建 10 个小文件，分四批（chunkSize=3）删除
        var manyFiles: [URL] = []
        let batchDir = appCacheDir.appendingPathComponent("batch")
        try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        for i in 0..<10 {
            let url = batchDir.appendingPathComponent("file\(i).txt")
            try? "data".write(to: url, atomically: true, encoding: .utf8)
            manyFiles.append(url)
        }
        let batchService = CleanupService(cleaner: DiskCleaner(allowedRoots: [base]))
        await batchService.scan()
        await batchService.clean(Set(manyFiles), chunkSize: 3)
        // 10 个文件分 4 批（3+3+3+1），最后都应被删除。
        let remaining = manyFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        check(remaining.isEmpty, "分批删除后所有文件均被删除")
        let stillListed = batchService.items.filter { manyFiles.contains($0.url) }
        check(stillListed.isEmpty, "删除的项已从服务列表移除")

        // 白名单外删除被拒绝
        let outside = URL(fileURLWithPath: "/tmp/mactoolbox_outside_\(UUID().uuidString).txt")
        try? "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let failOut = await cleaner.delete(at: [outside])
        check(!failOut.isEmpty, "白名单外删除被拒绝")
        check(FileManager.default.fileExists(atPath: outside.path), "外部文件未被删除")
    }
}
