import Foundation

/// 文件夹映射（软链接）服务：让用户自由选择源目录与目标位置，建立软链接。
/// 与磁盘挂载解耦，源可以是任意目录（磁盘、文件夹等）。
final class FolderMapService: ObservableObject, @unchecked Sendable {
    static let shared = FolderMapService()

    @Published private(set) var entries: [SymLinkEntry] = []

    private init() {
        reload()
    }

    // MARK: - 软链接结果

    enum SymLinkResult {
        case success(linkPath: String, targetPath: String)
        case failed(message: String)
        /// 目标位置已存在且非空，不能覆盖
        case targetOccupied(path: String)
    }

    // MARK: - 列表

    /// 重新加载已记录的软链接，并校验其有效性。
    /// 文件 I/O（exists / 属性 / 解析符号链接目标）放到后台队列，避免阻塞主线程
    /// （本服务在 `init()` 即调用，首屏可能触发）。
    func reload() {
        let links = ConfigStore.shared.allSymLinks()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var list: [SymLinkEntry] = []
            for (linkPath, target) in links {
                list.append(SymLinkEntry(
                    linkPath: linkPath,
                    targetPath: target,
                    isValid: self?.isValidSymLink(linkPath) ?? false
                ))
            }
            // 按链接路径排序，便于阅读
            list.sort { $0.linkPath < $1.linkPath }
            DispatchQueue.main.async {
                self?.entries = list
            }
        }
    }

    // MARK: - 创建

    /// 在 `linkPath` 创建一个指向 `targetPath` 的软链接。
    /// - 若 `linkPath` 是空目录：先移除再创建软链接
    /// - 若 `linkPath` 非空目录或已存在的文件：拒绝覆盖
    @discardableResult
    func create(targetPath: String, linkPath: String) -> SymLinkResult {
        let t = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = linkPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !l.isEmpty else {
            return .failed(message: "源目录与目标位置均不能为空")
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: l, isDirectory: &isDir) {
            if isDir.boolValue {
                do {
                    let contents = try fm.contentsOfDirectory(atPath: l)
                    if contents.isEmpty {
                        try fm.removeItem(atPath: l)
                    } else {
                        return .targetOccupied(path: l)
                    }
                } catch {
                    return .failed(message: "无法清理目标位置：\(error.localizedDescription)")
                }
            } else {
                // 已存在且不是目录（普通文件或软链接），不覆盖
                return .targetOccupied(path: l)
            }
        }

        let result = ShellExecutor.run("/bin/ln", arguments: ["-s", t, l])
        if result.exitCode == 0 {
            Logger.shared.info("Symlink \(l) -> \(t)")
            ConfigStore.shared.setSymLink(l, t)
            reload()
            return .success(linkPath: l, targetPath: t)
        } else {
            let msg = result.stderr.isEmpty ? "创建软链接失败" : result.stderr
            Logger.shared.error("Symlink failed: \(msg)")
            return .failed(message: msg)
        }
    }

    // MARK: - 删除

    /// 删除一条软链接（仅当该路径确实是软链接时才删除，避免误删真实目录）
    func remove(_ linkPath: String) {
        let l = linkPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return }
        guard isSymLink(l) else {
            Logger.shared.warning("Not a symlink, skip remove: \(l)")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: l)
            Logger.shared.info("Removed symlink \(l)")
        } catch {
            Logger.shared.error("Failed to remove symlink \(l): \(error.localizedDescription)")
        }
        ConfigStore.shared.removeSymLink(l)
        reload()
    }

    // MARK: - 校验

    /// 是否为软链接（符号链接）
    private func isSymLink(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        // 软链接本身 isDir 可能为 true/false，需看是否符号链接
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
        } catch {
            return false
        }
    }

    /// 软链接当前是否有效（存在且为符号链接；其目标是否存在另由 isValid 体现）
    private func isValidSymLink(_ path: String) -> Bool {
        guard isSymLink(path) else { return false }
        // 目标是否可达：用 destinationItem 解析
        do {
            let dest = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            return FileManager.default.fileExists(atPath: dest)
        } catch {
            return false
        }
    }
}

/// 一条已记录的软链接
struct SymLinkEntry: Identifiable, Equatable {
    var id: String { linkPath }
    let linkPath: String
    let targetPath: String
    let isValid: Bool
}
