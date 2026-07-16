import AppKit
import Foundation

/// 六个动作的具体执行（均在主线程调用，由 RightClickService 在收到扩展点击后分派）。
@MainActor
struct RightClickActionHandlers {

    static func perform(_ payload: RCClickPayload) {
        let targets = payload.targets.compactMap { URL(string: $0) }
        switch payload.item {
        case "newFile":       createNewFile(type: payload.subItem, targets: targets, targetedDir: payload.targetedDir)
        case "copyPath":      copyPaths(targets)
        case "openWith":      openWith(bundleID: payload.subItem, targets: targets)
        case "delete":        deleteDirectly(targets)
        case "toggleHidden":  toggleHidden(targets)
        case "openCommonDir": openDir(payload.subItem)
        default:              rcLog("RightClick: unknown action \(payload.item)")
        }
    }

    // MARK: 新建文件

    static func createNewFile(type: String?, targets: [URL], targetedDir: String?) {
        let ext = (type ?? "txt").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseDir = resolveBaseDir(targets: targets, targetedDir: targetedDir)
        var fileURL = baseDir.appendingPathComponent("untitled.\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = baseDir.appendingPathComponent("untitled-\(counter).\(ext)")
            counter += 1
        }
        do {
            try Data().write(to: fileURL)
            rcLog("RightClick: created \(fileURL.path)")
        } catch {
            rcLog("RightClick: create failed: \(error.localizedDescription)")
        }
    }

    private static func resolveBaseDir(targets: [URL], targetedDir: String?) -> URL {
        if let firstDir = targets.first(where: { isDirectory($0) }) { return firstDir }
        if let d = targetedDir, let u = URL(string: d), u.isFileURL, isDirectory(u) { return u }
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first { return desktop }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: 复制路径

    static func copyPaths(_ targets: [URL]) {
        guard !targets.isEmpty else { return }
        let text = targets.map { $0.path }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        rcLog("RightClick: copied \(targets.count) path(s)")
    }

    // MARK: 用 App 打开

    static func openWith(bundleID: String?, targets: [URL]) {
        guard let bundleID, !bundleID.isEmpty, !targets.isEmpty else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            rcLog("RightClick: app not found for bundleID \(bundleID)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(targets, withApplicationAt: appURL, configuration: configuration) { _, error in
            rcLog("RightClick: openWith \(bundleID) -> \(error == nil)")
        }
    }

    // MARK: 直接删除（跳过废纸篓，带确认 + 系统路径守卫）

    static func deleteDirectly(_ targets: [URL]) {
        guard !targets.isEmpty else { return }
        let guarded: [String] = ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/var", "/Library/Apple", "/Applications"]
        let isSystem = { (u: URL) in guarded.contains(where: { u.path.hasPrefix($0) }) }
        let unsafe = targets.filter(isSystem)
        let safe = targets.filter { !isSystem($0) }
        for u in unsafe {
            rcLog("RightClick: refused delete of system path \(u.path)")
        }
        guard !safe.isEmpty else { return }
        let names = safe.map { $0.lastPathComponent }.joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = "永久删除文件"
        alert.informativeText = "将直接删除（不进废纸篓）：\n\(names)\n此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for u in safe {
            do { try FileManager.default.removeItem(at: u) }
            catch { rcLog("RightClick: delete failed \(u.path): \(error.localizedDescription)") }
        }
    }

    // MARK: 隐藏 / 显示

    static func toggleHidden(_ targets: [URL]) {
        guard !targets.isEmpty else { return }
        for u in targets {
            do {
                let hidden = (try u.resourceValues(forKeys: [.isHiddenKey])).isHidden ?? false
                var copy = u
                var rv = URLResourceValues()
                rv.isHidden = !hidden
                try copy.setResourceValues(rv)
                rcLog("RightClick: toggleHidden \(u.lastPathComponent) -> \(!hidden)")
            } catch {
                rcLog("RightClick: toggleHidden failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: 打开常用目录

    static func openDir(_ path: String?) {
        guard let path, let url = URL(string: path), url.isFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: App 信息提取（供设置页添加 / 扫描）

    static func makeApp(from url: URL) -> RCOpenWithApp? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return RCOpenWithApp(name: name, bundleID: bundleID, path: url.path)
    }
}
