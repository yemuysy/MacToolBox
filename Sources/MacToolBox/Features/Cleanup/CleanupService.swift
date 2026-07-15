import Foundation

/// 垃圾清理服务（SwiftUI 桥接层）。
///
/// 封装 `DiskCleaner` actor：所有耗时扫描/删除在 actor 执行器（后台）进行，
/// 结果通过 `@MainActor` 写回 `@Published` 供 SwiftUI 绑定。
///
/// 选择性能优化（对应需求：选择卡顿）：
/// 1. 扫描时按「类别 × 应用」聚合成 `CleanupGroup`，UI 行数从「每个文件」收敛到「每个应用」（几十行）。
/// 2. 预构建 `sizeByURL` 字典，选中总字节数由 O(N²)（`first(where:)` 线性查找）降到 O(N)。
/// 3. 每个 `CleanupGroup` 预存 `urlSet`，组三态判定只需 O(组大小) 的集合求交。
///
/// 遵循项目约定：`ObservableObject` + `@unchecked Sendable`（单例、主线程绑定，
/// 跨线程写 UI 均经 `Task { @MainActor in }` 桥接）。
final class CleanupService: ObservableObject, @unchecked Sendable {
    static let shared = CleanupService()

    // MARK: - 状态（仅主线程写入）

    /// 扁平列表，保留原始顺序（供删除回写与测试断言）。
    @Published private(set) var items: [CleanupItem] = []

    /// 按「类别 → 应用组」分组后的结果，供 UI 折叠展示。扫描完成后一次性构建。
    @Published private(set) var groupsByCategory: [CleanupCategory: [CleanupGroup]] = [:]

    /// 每个类别的总字节数。
    @Published private(set) var categoryTotalSize: [CleanupCategory: Int64] = [:]

    /// 当前总扫描大小。
    @Published private(set) var totalSize: Int64 = 0

    /// 扫描中。
    @Published private(set) var isScanning: Bool = false

    /// 清理中。
    @Published private(set) var isCleaning: Bool = false

    /// 清理进度：当前处理到第几个 / 共几个。
    @Published private(set) var cleanProgress: (current: Int, total: Int) = (0, 0)

    /// 上次清理删除的字节数
    @Published private(set) var lastCleanedBytes: Int64 = 0

    /// 上次删除中失败的条目（白名单拒绝 / 权限不足等）
    @Published private(set) var lastErrors: [URL: String] = [:]

    // MARK: - 内部

    /// 扫描期间增量累积的分组缓冲：groupID -> 该组 items。
    private var grouping: [String: [CleanupItem]] = [:]
    /// URL -> 字节数 预构建字典，供选中总字节数 O(1) 查询。
    private var sizeByURL: [URL: Int64] = [:]

    private let cleaner: DiskCleaner
    private var started = false

    init(cleaner: DiskCleaner = DiskCleaner()) {
        self.cleaner = cleaner
    }

    // MARK: - 启动（首次进入 Tab 时调用）

    func start() {
        guard !started else { return }
        started = true
        Logger.shared.info("CleanupService starting")
        Task { await scan() }
    }

    // MARK: - 扫描

    /// 扫描白名单目录（~/Library/Caches、~/Library/Logs 等），实时累积列表与总大小，
    /// 扫描结束后聚合为应用组供 UI 展示。
    @MainActor func scan() async {
        items = []
        grouping = [:]
        sizeByURL = [:]
        groupsByCategory = [:]
        categoryTotalSize = [:]
        totalSize = 0
        lastErrors = [:]
        lastCleanedBytes = 0
        cleanProgress = (0, 0)
        isScanning = true
        defer {
            isScanning = false
            buildGroupsFromGrouping()
        }

        let roots = cleaner.allowedRoots
        _ = await cleaner.scan(roots: roots) { [weak self] batch in
            await MainActor.run {
                self?.appendItems(batch)
            }
        }
    }

    /// 在主线程追加一批扫描结果，同步更新分组缓冲、类别统计与总大小。
    @MainActor fileprivate func appendItems(_ chunk: [CleanupItem]) {
        items.append(contentsOf: chunk)
        for item in chunk {
            grouping[CleanupGroup.id(for: item.category, app: item.appName), default: []].append(item)
            totalSize += item.size
            sizeByURL[item.url] = item.size
        }
    }

    /// 由 `grouping` 缓冲构建最终的应用组结构，并按大小排序，同时算出类别总字节。
    @MainActor private func buildGroupsFromGrouping() {
        var result: [CleanupCategory: [CleanupGroup]] = [:]
        var catSize: [CleanupCategory: Int64] = [:]
        for (_, its) in grouping {
            guard let first = its.first else { continue }
            let group = CleanupGroup(
                category: first.category,
                appName: first.appName,
                items: its,
                urlSet: Set(its.map { $0.url })
            )
            result[first.category, default: []].append(group)
            catSize[first.category, default: 0] += group.totalSize
        }
        for key in result.keys {
            result[key]?.sort { $0.totalSize > $1.totalSize }
        }
        groupsByCategory = result
        categoryTotalSize = catSize
    }

    // MARK: - 默认选择策略

    /// 从当前扫描结果中生成默认应勾选的安全项集合。
    /// 规则：只选中 `risk == .safe` 的项；谨慎项需用户手动确认。
    @MainActor func defaultSelection() -> Set<URL> {
        Set(items.filter { $0.risk == .safe }.map { $0.url })
    }

    /// 计算选中集合的总字节数（O(选中数)，依赖预构建的 `sizeByURL`）。
    @MainActor func selectedBytes(_ selected: Set<URL>) -> Int64 {
        selected.reduce(Int64(0)) { $0 + (sizeByURL[$1] ?? 0) }
    }

    // MARK: - 清理

    /// 删除选中的条目，按 `chunkSize` 分批执行，避免一次性大量文件系统操作卡死 UI。
    /// - Parameter selected: 待删除文件 URL 集合。
    /// - Parameter chunkSize: 每批处理的文件数，默认 50。
    @MainActor func clean(_ selected: Set<URL>, chunkSize: Int = 50) async {
        guard !selected.isEmpty else { return }
        isCleaning = true
        cleanProgress = (0, selected.count)
        defer {
            isCleaning = false
            cleanProgress = (0, 0)
        }

        let urls = Array(selected)
        var allFailures: [URL: String] = [:]
        var removedSize: Int64 = 0

        for start in stride(from: 0, to: urls.count, by: chunkSize) {
            let end = min(start + chunkSize, urls.count)
            let chunk = Array(urls[start..<end])
            let failures = await cleaner.delete(at: chunk)
            allFailures.merge(failures) { old, _ in old }

            let chunkRemoved = Set(chunk).subtracting(Set(failures.keys))

            // 在 @MainActor 上同步更新 UI，避免与后续批次竞争。
            let removedBytes = self.removeItems(chunkRemoved)
            removedSize += removedBytes
            self.totalSize -= removedBytes
            self.cleanProgress.current = end

            // 给事件循环喘息机会，避免大文件或权限对话框阻塞。
            if end < urls.count {
                await Task.yield()
            }
        }

        lastErrors = allFailures
        lastCleanedBytes = removedSize
    }

    /// 在主线程移除指定 URL 并同步重建分组与类别统计，返回移除的总字节数。
    @MainActor private func removeItems(_ removed: Set<URL>) -> Int64 {
        var removedBytes: Int64 = 0
        items.removeAll {
            if removed.contains($0.url) {
                removedBytes += $0.size
                sizeByURL[$0.url] = nil
                return true
            }
            return false
        }
        rebuildGroupingFromItems()
        buildGroupsFromGrouping()
        return removedBytes
    }

    /// 由当前 `items` 重新构建分组缓冲（删除后调用）。
    @MainActor private func rebuildGroupingFromItems() {
        var g: [String: [CleanupItem]] = [:]
        for it in items {
            g[CleanupGroup.id(for: it.category, app: it.appName), default: []].append(it)
        }
        grouping = g
    }

    /// 便捷：清空选择并重置错误
    func clearResults() {
        Task { @MainActor in
            items = []
            grouping = [:]
            sizeByURL = [:]
            groupsByCategory = [:]
            categoryTotalSize = [:]
            totalSize = 0
            lastErrors = [:]
            lastCleanedBytes = 0
            cleanProgress = (0, 0)
        }
    }
}
