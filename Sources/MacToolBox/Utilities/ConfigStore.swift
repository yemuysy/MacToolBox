import Foundation

/// 简易持久化存储，所有配置以 JSON 形式写入 Application Support 目录
final class ConfigStore: @unchecked Sendable {
    static let shared = ConfigStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.yemu.mactoolbox.configstore")
    // 已挂载卷的记忆：卷名 -> 挂载路径（用于开机自动恢复）
    private var mountPointsStorage: [String: String] = [:]
    // 软链接映射：链接路径 -> 目标路径
    private var symLinkStorage: [String: String] = [:]
    // 菜单栏显示配置
    private var menuBarStorage: MenuBarConfig = MenuBarConfig()
    // 滚轮控制配置
    private var scrollControlStorage: ScrollControlConfig = ScrollControlConfig()
    // 右键增强配置
    private var rightClickStorage: RightClickConfig = RightClickConfig()
    // hosts 方案（SwitchHosts 类功能）
    private var hostSchemesStorage: [HostScheme] = []

    // 功能开关 + 快捷键（独立文件 features.json，避免破坏旧 config.json 结构）
    private var featureEnabledStorage: Set<String> = []
    private var featureConfigured = false
    private var hotkeyBindingsStorage: [String: Hotkey] = [:]
    private let featuresURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("MacToolBox", isDirectory: true)

        guard let dir = appSupport else {
            fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mactoolbox-config.json")
            featuresURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mactoolbox-features.json")
            return
        }

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")
        featuresURL = dir.appendingPathComponent("features.json")
        load()
        loadFeatures()
    }

    // MARK: - 挂载路径记忆（开机自动恢复）

    /// 记录某卷上次挂载到的路径
    func setMountPoint(_ volumeName: String, _ path: String) {
        let v = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !p.isEmpty else { return }
        queue.sync(flags: .barrier) {
            mountPointsStorage[v] = p
            save()
        }
    }

    /// 所有记忆的挂载路径
    func allMountPoints() -> [String: String] {
        queue.sync { mountPointsStorage }
    }

    // MARK: - 菜单栏显示配置

    /// 菜单栏实时数据项的显示开关
    struct MenuBarConfig: Codable {
        var showStats: Bool = true      // 总开关：是否在菜单栏显示数据
        var showCPU: Bool = true        // CPU 使用率
        var showMemory: Bool = true     // 内存占用
        var showNetwork: Bool = true    // 网速（下行/上行）
        var showTemperature: Bool = true // 温度
    }

    func menuBarConfig() -> MenuBarConfig {
        queue.sync { menuBarStorage }
    }

    func setMenuBarConfig(_ config: MenuBarConfig) {
        queue.sync(flags: .barrier) {
            menuBarStorage = config
            save()
        }
    }

    // MARK: - 滚轮控制配置

    /// 滚轮拦截 / 反向 / 平滑参数（参照 Mos）
    struct ScrollControlConfig: Codable, Sendable {
        var enabled: Bool = false           // 是否启用全局拦截
        var reverseVertical: Bool = true    // 纵向反向（鼠标滚轮方向自然化）
        var reverseHorizontal: Bool = false // 横向反向
        var smooth: Bool = true             // 平滑滚动
        var smoothStep: Double = 0.3        // 平滑度：每帧消耗剩余量比例 0.1~0.9（越大越跟手）
        var smoothSpeed: Double = 3.0       // 加速度：原始 delta 放大倍率 1~10
        var excludeTrackpad: Bool = true    // 触控板豁免（保持原生手感）
    }

    func scrollControlConfig() -> ScrollControlConfig {
        queue.sync { scrollControlStorage }
    }

    func setScrollControlConfig(_ config: ScrollControlConfig) {
        queue.sync(flags: .barrier) {
            scrollControlStorage = config
            save()
        }
    }

    // MARK: - 右键增强配置

    /// Finder 右键菜单配置（类型定义见 Features/RightClick/RightClickModels.swift）
    func rightClickConfig() -> RightClickConfig {
        queue.sync { rightClickStorage }
    }

    func setRightClickConfig(_ config: RightClickConfig) {
        queue.sync(flags: .barrier) {
            rightClickStorage = config
            save()
        }
    }

    // MARK: - hosts 方案（SwitchHosts 类功能）

    func hostSchemes() -> [HostScheme] {
        queue.sync { hostSchemesStorage }
    }

    func setHostSchemes(_ schemes: [HostScheme]) {
        queue.sync(flags: .barrier) {
            hostSchemesStorage = schemes
            save()
        }
    }

    // MARK: - 软链接映射（独立功能）

    /// 记录一条软链接：链接路径 -> 目标路径
    func setSymLink(_ linkPath: String, _ targetPath: String) {
        let l = linkPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !t.isEmpty else { return }
        queue.sync(flags: .barrier) {
            symLinkStorage[l] = t
            save()
        }
    }

    /// 所有记忆的软链接（链接路径 -> 目标路径）
    func allSymLinks() -> [String: String] {
        queue.sync { symLinkStorage }
    }

    func removeSymLink(_ linkPath: String) {
        queue.sync(flags: .barrier) {
            symLinkStorage.removeValue(forKey: linkPath)
            save()
        }
    }

    // MARK: - Persistence

    private struct PersistedData: Codable {
        var mountPoints: [String: String]
        var symLinks: [String: String]
        var menuBar: MenuBarConfig
        // 可选：旧版 config.json 无此字段时解码为 nil，避免整体解码失败丢失其它配置
        var scrollControl: ScrollControlConfig?
        var rightClick: RightClickConfig?
        var hosts: [HostScheme]?
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let parsed = try? JSONDecoder().decode(PersistedData.self, from: data) else {
            return
        }
        mountPointsStorage = parsed.mountPoints
        symLinkStorage = parsed.symLinks
        menuBarStorage = parsed.menuBar
        if let sc = parsed.scrollControl { scrollControlStorage = sc }
        if let rc = parsed.rightClick { rightClickStorage = rc }
        if let h = parsed.hosts { hostSchemesStorage = h }
    }

    private func save() {
        let payload = PersistedData(
            mountPoints: mountPointsStorage,
            symLinks: symLinkStorage,
            menuBar: menuBarStorage,
            scrollControl: scrollControlStorage,
            rightClick: rightClickStorage,
            hosts: hostSchemesStorage
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 功能开关

    /// 返回 (已启用功能 rawValue 集合, 是否已配置过)
    func featureStates() -> (enabled: Set<String>, configured: Bool) {
        queue.sync { (featureEnabledStorage, featureConfigured) }
    }

    func setFeatureStates(_ enabled: [String]) {
        queue.sync(flags: .barrier) {
            featureEnabledStorage = Set(enabled)
            featureConfigured = true
            saveFeatures()
        }
    }

    // MARK: - 快捷键绑定

    func hotkeyBindings() -> [String: Hotkey] {
        queue.sync { hotkeyBindingsStorage }
    }

    func setHotkeyBinding(_ hotkey: Hotkey, for action: HotkeyAction) {
        queue.sync(flags: .barrier) {
            if hotkey.isNone {
                hotkeyBindingsStorage.removeValue(forKey: action.rawValue)
            } else {
                hotkeyBindingsStorage[action.rawValue] = hotkey
            }
            saveFeatures()
        }
    }

    func resetHotkeys() {
        queue.sync(flags: .barrier) {
            hotkeyBindingsStorage.removeAll()
            saveFeatures()
        }
    }

    // MARK: - Features Persistence (独立文件)

    private struct FeaturePersist: Codable {
        var enabled: [String]
        var configured: Bool
        var hotkeys: [String: Hotkey]
    }

    private func loadFeatures() {
        guard FileManager.default.fileExists(atPath: featuresURL.path),
              let data = try? Data(contentsOf: featuresURL),
              let parsed = try? JSONDecoder().decode(FeaturePersist.self, from: data) else {
            return
        }
        featureEnabledStorage = Set(parsed.enabled)
        featureConfigured = parsed.configured
        hotkeyBindingsStorage = parsed.hotkeys
    }

    /// 不进队列：调用方需已在 barrier 内持有队列
    private func saveFeatures() {
        let payload = FeaturePersist(
            enabled: Array(featureEnabledStorage),
            configured: featureConfigured,
            hotkeys: hotkeyBindingsStorage
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: featuresURL, options: .atomic)
    }
}
