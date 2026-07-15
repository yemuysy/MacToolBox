import Foundation

// MARK: - 分类模型

/// 垃圾类别，对应腾讯柠檬式的大类。
enum CleanupCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"       // 系统垃圾
    case application = "app"     // 应用垃圾
    case internet = "internet"   // 上网垃圾

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "系统垃圾"
        case .application: return "应用垃圾"
        case .internet: return "上网垃圾"
        }
    }

    var icon: String {
        switch self {
        case .system: return "gear"
        case .application: return "app.fill"
        case .internet: return "globe"
        }
    }

    var colorName: String {
        switch self {
        case .system: return "orange"
        case .application: return "blue"
        case .internet: return "green"
        }
    }
}

/// 风险等级，决定默认是否勾选。
enum CleanupRisk: Int, Codable, Sendable, Comparable {
    case safe = 0      // 可安全清理（默认勾选）
    case caution = 1   // 需谨慎（默认不勾选）
    case critical = 2  // 不建议清理（本项目默认不扫描）

    static func < (lhs: CleanupRisk, rhs: CleanupRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 单个可清理项。`Sendable` 以便跨 actor 边界通过回调暴露给 UI。
struct CleanupItem: Identifiable, Sendable {
    let url: URL
    var id: URL { url }
    let path: String
    let size: Int64
    let isDirectory: Bool
    let category: CleanupCategory
    let appName: String        // 所属应用名称（系统垃圾为空）
    let risk: CleanupRisk
    let kind: String           // 人类可读的种类，例如 "缓存文件" / "日志文件"
}

/// 按「类别 + 应用」聚合的一组可清理项，是 UI 选择与展示的最小单元。
///
/// 用户通常以「应用」为单位决定是否清理。把扁平的几万个文件收敛成几十个应用组，
/// 可将 SwiftUI 视图数量从 O(N) 降到 O(应用数)，并把选择字节计算从 O(N²) 降到 O(N)。
struct CleanupGroup: Identifiable, Sendable {
    let category: CleanupCategory
    let appName: String
    let items: [CleanupItem]
    /// 该组全部成员 URL 的预构建集合，供选择求交 / 清理时直接取用，避免每次渲染重复构建。
    let urlSet: Set<URL>

    var id: String { Self.id(for: category, app: appName) }

    static func id(for category: CleanupCategory, app: String) -> String {
        "\(category.rawValue)|\(app.isEmpty ? "__system__" : app)"
    }

    var count: Int { items.count }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    /// 组是否整体安全（全部成员 risk == .safe），用于默认勾选判定与三态展示。
    var isSafe: Bool { items.allSatisfy { $0.risk == .safe } }
    /// 展示名：应用组显示应用名，系统垃圾显示「系统文件」。
    var displayName: String { appName.isEmpty ? "系统文件" : appName }
}

// MARK: - 分类规则引擎

/// 给定一个被扫到的文件 URL，判断其类别、应用名、风险与种类。
struct CleanupClassifier {

    /// 浏览器 Bundle ID 与对应显示名。Caches 下命中这些视为「上网垃圾」。
    private static let browserBundleIDs: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome Canary",
        "org.mozilla.firefox": "Firefox",
        "com.operasoftware.Opera": "Opera",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "com.qihoo.quarkmac": "夸克",
        "com.tencent.qqbrowser": "QQ浏览器",
        "com.vivaldi.Vivaldi": "Vivaldi"
    ]

    /// 常见应用 Bundle ID 映射。Caches 下非浏览器命中这些视为「应用垃圾」。
    private static let appBundleIDs: [String: String] = [
        "com.tencent.qq": "QQ",
        "com.tencent.xinWeChat": "微信",
        "com.netease.163music": "网易云音乐",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.apple.dt.Xcode": "Xcode",
        "com.apple.mail": "Mail",
        "com.apple.iChat": "信息",
        "com.apple.podcasts": "播客",
        "com.apple.music": "音乐",
        "com.apple.tv": "TV",
        "com.apple.AppStore": "App Store",
        "com.apple.dock": "Dock",
        "com.apple.finder": "Finder",
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Chrome",
        "org.mozilla.firefox": "Firefox",
        "com.operasoftware.Opera": "Opera",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "com.qihoo.quarkmac": "夸克",
        "com.tencent.qqbrowser": "QQ浏览器",
        "com.vivaldi.Vivaldi": "Vivaldi"
    ]

    /// 根据路径与父目录信息判断分类。
    static func classify(_ url: URL, parentRoot: URL) -> (category: CleanupCategory, appName: String, risk: CleanupRisk, kind: String) {
        let path = url.path
        let parent = url.deletingLastPathComponent().path

        // 1. 系统垃圾：Logs / tmp / 系统临时目录 / 用户日志目录
        if parentRoot.lastPathComponent == "Logs" ||
            parentRoot.path.hasSuffix("/Library/Logs") ||
            path.contains("/var/tmp") ||
            path.contains("/tmp/") ||
            parentRoot.lastPathComponent == "TemporaryItems" ||
            parentRoot.path.hasSuffix("/T") ||
            parentRoot.path.hasSuffix("/tmp") {
            return (.system, "", .safe, "日志/临时文件")
        }

        // 2. 上网垃圾：Caches 下命中浏览器 bundle id
        if parentRoot.lastPathComponent == "Caches" || path.contains("/Library/Caches/") {
            for (bundle, name) in browserBundleIDs {
                if parent.contains("/\(bundle)/") || parent.contains("/\(bundle)") || url.lastPathComponent == bundle {
                    return (.internet, name, .safe, "浏览器缓存")
                }
            }
            // 3. 应用垃圾：Caches 下命中应用 bundle id
            for (bundle, name) in appBundleIDs {
                if parent.contains("/\(bundle)/") || parent.contains("/\(bundle)") || url.lastPathComponent == bundle {
                    return (.application, name, .safe, "应用缓存")
                }
            }
            // 未识别的 Caches 子项：仍归为应用垃圾，风险为 safe（缓存通常是安全的）
            return (.application, bundleDisplayName(url), .safe, "应用缓存")
        }

        // 兜底：按扩展名/路径名猜测
        if path.contains("/Caches/") {
            return (.application, bundleDisplayName(url), .safe, "应用缓存")
        }
        if path.contains("/Logs/") {
            return (.system, "", .safe, "日志文件")
        }

        return (.system, "", .safe, "系统垃圾")
    }

    /// 从路径中提取一个可读的 bundle 显示名（例如 com.example.foo → foo）。
    private static func bundleDisplayName(_ url: URL) -> String {
        let candidate = url.deletingLastPathComponent().lastPathComponent
        if candidate.contains(".") {
            return candidate.components(separatedBy: ".").last ?? candidate
        }
        return candidate
    }
}

// MARK: - 垃圾清理引擎（actor）

/// 用户级垃圾清理引擎。
///
/// 设计要点（对应需求规范）：
/// 1. 使用 `actor` 隔离可变状态，所有文件 I/O 在 actor 串行执行器（非主线程）上异步进行，
///    绝不阻塞主线程（Main Thread）。
/// 2. 递归扫描 `~/Library/Caches` 与 `~/Library/Logs`，通过 `@Sendable` 回调把「当前扫描到的
///    文件路径 + 大小」安全地派发回调用方（调用方负责桥接到 `@MainActor` 更新 SwiftUI）。
/// 3. `delete(at:)` 对越白名单、只读或无权文件做 try-catch 保护，跳过并集中记录错误，绝不崩溃。
/// 4. **白名单保护**：仅允许扫描/删除 `allowedRoots` 前缀下的路径。默认覆盖用户的
///    Caches / Logs / 临时目录；测试时通过 `init(allowedRoots:)` 注入沙盒目录即可。
/// 5. **分类**：每个 CleanupItem 都携带 category / appName / risk，供 UI 分组展示与默认选中。
///
/// 注意：该类型只依赖 Foundation，可被独立 `swift` 命令编译（用于沙盒单测），无需 AppKit。
actor DiskCleaner {

    /// 允许扫描/删除的根目录集合。任何不在此前缀树下的路径都会被拒绝。
    let allowedRoots: [URL]

    /// 默认白名单：当前用户的 Caches、Logs、系统临时目录。
    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Logs"),
            URL(fileURLWithPath: NSTemporaryDirectory())
        ]
    }

    /// - Parameter allowedRoots: 自定义白名单（用于沙盒测试）。为空时退回默认用户目录。
    init(allowedRoots: [URL]? = nil) {
        if let allowedRoots, !allowedRoots.isEmpty {
            self.allowedRoots = allowedRoots.map { $0.standardized }
        } else {
            self.allowedRoots = Self.defaultRoots
        }
    }

    /// 校验某 URL 是否落在白名单前缀树内（含根本身）。
    func isAllowed(_ url: URL) -> Bool {
        let path = url.standardized.path
        return allowedRoots.contains { root in
            let rp = root.path
            return path == rp || path.hasPrefix(rp + "/")
        }
    }

    /// 扫描给定根目录，批量通过 `report` 暴露文件（每攒够一批才跨 actor 回传一次，
    /// 避免逐个文件跨 actor 边界导致的性能雪崩），返回累计字节数。
    /// - Parameter roots: 待扫描根目录。不在白名单内的根会被自动跳过。
    /// - Parameter report: `@Sendable` 异步回调，每批量（默认 256 个）文件调用一次。
    func scan(roots: [URL], report: @Sendable @escaping ([CleanupItem]) async -> Void) async -> Int64 {
        let batchSize = 256
        var total: Int64 = 0
        for root in roots where isAllowed(root) {
            // scanDirectory 完全同步、无 actor hop，返回该根下全部文件。
            let collected = scanDirectory(root, parentRoot: root)
            total += collected.reduce(0) { $0 + $1.size }
            // 分批回传：每 batchSize 个文件才跨一次 actor 边界。
            var idx = 0
            while idx < collected.count {
                let end = min(idx + batchSize, collected.count)
                let chunk = Array(collected[idx..<end])
                await report(chunk)
                idx = end
            }
        }
        return total
    }

    /// 同步枚举目录，返回扫到的全部 `CleanupItem`（无 actor hop，纯本地计算）。
    private func scanDirectory(_ url: URL, parentRoot: URL) -> [CleanupItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [CleanupItem] = []
        // 同步的 `nextObject()` 迭代：枚举在 actor 执行器（后台线程）上阻塞，不阻塞主线程。
        while let next = enumerator.nextObject() {
            guard let fileURL = next as? URL else { continue }
            // 逐个文件 try-catch：权限不足/不可达的文件直接跳过，绝不让整个扫描崩溃。
            do {
                let resource = try fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey]
                )
                let isDir = resource.isDirectory ?? false
                let size: Int64 = isDir ? 0 : Int64(resource.fileSize ?? 0)
                let (category, appName, risk, kind) = CleanupClassifier.classify(fileURL, parentRoot: parentRoot)
                result.append(CleanupItem(
                    url: fileURL,
                    path: fileURL.path,
                    size: size,
                    isDirectory: isDir,
                    category: category,
                    appName: appName,
                    risk: risk,
                    kind: kind
                ))
            } catch {
                continue
            }
        }
        return result
    }

    /// 删除指定 URL 集合，返回「未能删除」的 `url -> 错误描述` 映射。
    /// - 不在白名单内的 URL 一律拒绝并记录（安全保护），不执行任何文件系统写入。
    /// - 只读 / 无权限文件捕获异常后跳过，不崩溃。
    func delete(at urls: [URL]) -> [URL: String] {
        let fm = FileManager.default
        var failures: [URL: String] = [:]

        for url in urls {
            guard isAllowed(url) else {
                failures[url] = "安全保护：不在允许删除的白名单目录内，已跳过。"
                continue
            }
            do {
                try fm.removeItem(at: url)
            } catch {
                failures[url] = error.localizedDescription
            }
        }
        return failures
    }
}
