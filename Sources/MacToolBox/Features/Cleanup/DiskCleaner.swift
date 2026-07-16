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
    /// 来源标签（如「用户缓存」「废纸篓」），照 Clean-Me 的清理项分类地图展示。
    let source: String
    /// 是否系统级目标：删除需管理员权限，普通权限下会失败并记录（照 KnockKnock 的可管理性标记）。
    let needsAdmin: Bool

    init(url: URL, path: String, size: Int64, isDirectory: Bool, category: CleanupCategory,
         appName: String, risk: CleanupRisk, kind: String, source: String = "", needsAdmin: Bool = false) {
        self.url = url
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.category = category
        self.appName = appName
        self.risk = risk
        self.kind = kind
        self.source = source
        self.needsAdmin = needsAdmin
    }
}

/// 按「类别 + 应用」聚合的一组可清理项，是 UI 选择与展示的最小单元。
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

// MARK: - 清理目标清单（照 Clean-Me 的「路径地图」）

/// 单个清理目标（一组根路径）。照 Clean-Me 把需清理的系统目录集中定义为路径地图，
/// 系统级目录标记 `needsAdmin`（普通权限可扫描但删除会被系统拒绝，UI 上给出管理员提示）。
///
/// 设计要点（安全，同 Clean-Me）：
/// - 只删除**目录内容**，绝不删除根目录本身；
/// - 扫描/删除都严格限制在 `root` 前缀树内（白名单）。
struct CleanupTarget: Identifiable, Sendable {
    let id: String
    let displayName: String
    let root: URL
    let needsAdmin: Bool
    let icon: String
}

enum CleanupTargets {
    /// 默认清理目标地图（照 Clean-Me + cleanmymac 融合）。
    static let all: [CleanupTarget] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            CleanupTarget(id: "user-cache", displayName: "用户缓存",
                          root: home.appendingPathComponent("Library/Caches"), needsAdmin: false, icon: "folder"),
            CleanupTarget(id: "system-cache", displayName: "系统缓存",
                          root: URL(fileURLWithPath: "/Library/Caches"), needsAdmin: true, icon: "folder.fill"),
            CleanupTarget(id: "user-logs", displayName: "用户日志",
                          root: home.appendingPathComponent("Library/Logs"), needsAdmin: false, icon: "doc.text"),
            CleanupTarget(id: "system-logs", displayName: "系统日志",
                          root: URL(fileURLWithPath: "/Library/Logs"), needsAdmin: true, icon: "doc.text.fill"),
            CleanupTarget(id: "tmp", displayName: "临时文件",
                          root: URL(fileURLWithPath: NSTemporaryDirectory()), needsAdmin: false, icon: "clock"),
            CleanupTarget(id: "xcode", displayName: "Xcode 派生数据",
                          root: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), needsAdmin: false, icon: "hammer"),
            CleanupTarget(id: "trash", displayName: "废纸篓",
                          root: home.appendingPathComponent(".Trash"), needsAdmin: false, icon: "trash"),
        ]
    }()
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

    /// 开发者工具缓存目录名 → 显示名（照 cleanmymac 的 dev 分类）。
    private static let devToolDirs: [String: String] = [
        "DerivedData": "Xcode",
        "com.apple.dt.Xcode": "Xcode",
        "npm": "npm",
        "Homebrew": "Homebrew",
        "org.swift.swiftpm": "SwiftPM",
        "go-build": "Go",
        "cargo": "Cargo",
        "com.apple.llvm": "Clang/LLVM",
        "com.apple.dt.CoreSimulator": "iOS Simulator",
        "android": "Android SDK"
    ]

    /// 根据路径与父目录信息判断分类。
    static func classify(_ url: URL, parentRoot: URL) -> (category: CleanupCategory, appName: String, risk: CleanupRisk, kind: String) {
        let path = url.path
        let parent = url.deletingLastPathComponent().path
        let lastName = url.deletingLastPathComponent().lastPathComponent

        // 1. 系统垃圾：Logs / tmp / 系统临时目录
        if parentRoot.lastPathComponent == "Logs" ||
            parentRoot.path.hasSuffix("/Library/Logs") ||
            path.contains("/var/tmp") ||
            path.contains("/tmp/") ||
            parentRoot.lastPathComponent == "TemporaryItems" ||
            parentRoot.path.hasSuffix("/T") ||
            parentRoot.path.hasSuffix("/tmp") {
            return (.system, "", .safe, "日志/临时文件")
        }

        // 1.5 开发者工具特殊路径（不在 Caches 下，需在 Caches 判定前识别）
        if path.contains("/Developer/Xcode/DerivedData") {
            return (.application, "Xcode", .safe, "Xcode 派生数据")
        }
        if path.contains("/CoreSimulator/") {
            return (.application, "iOS Simulator", .safe, "模拟器缓存")
        }

        // 2. 上网垃圾：Caches 下命中浏览器 bundle id
        if parentRoot.lastPathComponent == "Caches" || path.contains("/Library/Caches/") {
            for (bundle, name) in browserBundleIDs {
                if parent.contains("/\(bundle)") || url.lastPathComponent == bundle {
                    return (.internet, name, .safe, "浏览器缓存")
                }
            }
            // 2.5 开发者工具（按目录名）
            if let devName = devToolDirs[lastName] {
                return (.application, devName, .safe, "开发工具缓存")
            }
            // 3. 应用垃圾：Caches 下命中应用 bundle id
            for (bundle, name) in appBundleIDs {
                if parent.contains("/\(bundle)") || url.lastPathComponent == bundle {
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

/// 用户级垃圾清理引擎（照 Clean-Me 的「路径地图 + 只删内容」模型扩展）。
///
/// 设计要点（对应需求规范）：
/// 1. 使用 `actor` 隔离可变状态，所有文件 I/O 在 actor 串行执行器（非主线程）上异步进行，
///    绝不阻塞主线程（Main Thread）。
/// 2. 按 `CleanupTarget` 清单扫描根目录，通过 `@Sendable` 回调把「当前扫描到的
///    文件路径 + 大小」安全地派发回调用方（调用方负责桥接到 `@MainActor` 更新 SwiftUI）。
/// 3. `delete(at:)` 对越白名单、只读、根目录本身或无权文件做 try-catch 保护，跳过并集中记录错误，绝不崩溃。
/// 4. **白名单保护**：仅允许扫描/删除 `targets` 中根目录前缀树下的路径。
/// 5. **只删内容不删根**：`isRoot` 保护，禁止删除清理目标根目录本身（Clean-Me 安全核心）。
/// 6. **分类**：每个 CleanupItem 都携带 category / appName / risk / source，供 UI 分组展示与默认选中。
///
/// 注意：该类型只依赖 Foundation，可被独立 `swift` 命令编译（用于沙盒单测），无需 AppKit。
actor DiskCleaner {

    /// 待清理目标清单。任何不在此前缀树下的路径都会被拒绝。
    let targets: [CleanupTarget]

    /// 默认目标地图。
    static var defaultTargets: [CleanupTarget] { CleanupTargets.all }

    /// 白名单根集合（targets 的 root 标准化）。
    var allowedRoots: [URL] { targets.map { $0.root.standardized } }

    /// 兼容旧调用：传入根目录数组时，自动包装为「用户级、无管理员需求」的 target。主要用于测试。
    init(allowedRoots: [URL]? = nil) {
        if let allowedRoots, !allowedRoots.isEmpty {
            self.targets = allowedRoots.map {
                CleanupTarget(id: $0.standardized.path, displayName: $0.lastPathComponent,
                              root: $0, needsAdmin: false, icon: "folder")
            }
        } else {
            self.targets = Self.defaultTargets
        }
    }

    /// 新 API：传入清理目标清单。
    init(targets: [CleanupTarget]) {
        self.targets = targets
    }

    /// 校验某 URL 是否落在白名单前缀树内（含根本身）。
    func isAllowed(_ url: URL) -> Bool {
        let path = url.standardized.path
        return allowedRoots.contains { root in
            let rp = root.path
            return path == rp || path.hasPrefix(rp + "/")
        }
    }

    /// 是否为某个清理目标的根目录本身（只删内容不删根）。
    func isRoot(_ url: URL) -> Bool {
        let p = url.standardized.path
        return targets.contains { $0.root.standardized.path == p }
    }

    /// 扫描给定目标，批量通过 `report` 暴露文件（每攒够一批才跨 actor 回传一次，
    /// 避免逐个文件跨 actor 边界导致的性能雪崩），返回累计字节数。
    /// - Parameter targets: 待扫描目标；为 nil 时扫描全部默认目标。不在白名单内的根会被自动跳过。
    /// - Parameter report: `@Sendable` 异步回调，每批量（默认 256 个）文件调用一次。
    func scan(targets: [CleanupTarget]? = nil, report: @Sendable @escaping ([CleanupItem]) async -> Void) async -> Int64 {
        let ts = targets ?? self.targets
        let batchSize = 256
        var total: Int64 = 0
        for target in ts where isAllowed(target.root) {
            // scanDirectory 完全同步、无 actor hop，返回该根下全部文件。
            let collected = scanDirectory(target.root, parentRoot: target.root, target: target)
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
    private func scanDirectory(_ url: URL, parentRoot: URL, target: CleanupTarget) -> [CleanupItem] {
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
                    kind: kind,
                    source: target.displayName,
                    needsAdmin: target.needsAdmin
                ))
            } catch {
                continue
            }
        }
        return result
    }

    /// 删除指定 URL 集合，返回「未能删除」的 `url -> 错误描述` 映射。
    /// - 不在白名单内的 URL 一律拒绝并记录（安全保护），不执行任何文件系统写入。
    /// - 根目录本身拒绝删除（只删内容不删根）。
    /// - 只读 / 无权限文件捕获异常后跳过，不崩溃。
    func delete(at urls: [URL]) -> [URL: String] {
        let fm = FileManager.default
        var failures: [URL: String] = [:]

        for url in urls {
            guard isAllowed(url) else {
                failures[url] = "安全保护：不在允许删除的白名单目录内，已跳过。"
                continue
            }
            guard !isRoot(url) else {
                failures[url] = "安全保护：不删除清理目标根目录本身，仅清理其内容。"
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
