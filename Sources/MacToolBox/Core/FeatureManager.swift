import SwiftUI
import Foundation

/// 单个功能的定义：元数据 + 视图工厂。
/// 视图工厂在功能被启用且用户切到该 Tab 时才调用，因此未启用功能的 Service 不会被实例化 —— 这是「功能开关省内存」的核心。
struct FeatureDefinition: Identifiable {
    let id: FeatureID
    let title: String
    let icon: String
    /// 核心功能不可关闭（概览常驻）
    let isCore: Bool
    /// 首次运行时的默认启用状态
    let defaultEnabled: Bool
    /// 构建该功能的根视图（含必要的 onAppear 启动逻辑）
    let makeContent: @MainActor () -> AnyView
}

/// 功能注册表 + 启用状态解析 + 惰性实例化控制。
/// 全 App 唯一的「功能真相来源」：侧边栏、菜单栏面板、快捷键均以其为驱动。
@MainActor
final class FeatureManager: ObservableObject {
    static let shared = FeatureManager()

    @Published private(set) var enabledIDs: Set<FeatureID>
    let definitions: [FeatureDefinition]

    private init() {
        self.definitions = Self.buildDefinitions()
        self.enabledIDs = Self.resolveEnabled(definitions: self.definitions)
    }

    // MARK: - 查询

    func isEnabled(_ id: FeatureID) -> Bool {
        isCore(id) ? true : enabledIDs.contains(id)
    }

    /// 是否核心功能（核心功能不可关闭，恒为启用）
    private func isCore(_ id: FeatureID) -> Bool {
        definitions.first(where: { $0.id == id })?.isCore ?? false
    }

    var enabledDefinitions: [FeatureDefinition] {
        definitions.filter { isEnabled($0.id) }
    }

    /// 默认着陆功能（核心概览）
    var landing: FeatureID { .overview }

    /// 返回一个功能的视图（未启用返回 nil）
    func content(for id: FeatureID) -> AnyView? {
        guard let def = definitions.first(where: { $0.id == id }), isEnabled(id) else { return nil }
        return def.makeContent()
    }

    // MARK: - 变更

    func setEnabled(_ id: FeatureID, _ on: Bool) {
        guard !isCore(id) else { return }
        if on { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        persist()
    }



    private func persist() {
        ConfigStore.shared.setFeatureStates(enabledIDs.map { $0.rawValue })
    }

    private static func resolveEnabled(definitions: [FeatureDefinition]) -> Set<FeatureID> {
        let (stored, configured) = ConfigStore.shared.featureStates()
        var set = Set<FeatureID>()
        for d in definitions where !d.isCore {
            if configured {
                if stored.contains(d.id.rawValue) { set.insert(d.id) }
            } else if d.defaultEnabled {
                set.insert(d.id)
            }
        }
        return set
    }

    // MARK: - 注册全部内置功能

    /// 新增功能：在此追加一个 FeatureDefinition 即可，导航/面板/快捷键自动生效。
    private static func buildDefinitions() -> [FeatureDefinition] {
        [
            FeatureDefinition(
                id: .overview, title: "概览", icon: "square.grid.2x2",
                isCore: true, defaultEnabled: true
            ) { AnyView(OverviewView()) },

            FeatureDefinition(
                id: .diskMount, title: "磁盘挂载", icon: "externaldrive",
                isCore: false, defaultEnabled: true
            ) { AnyView(DiskMountView().onAppear { DiskMountService.shared.start() }) },

            FeatureDefinition(
                id: .metalHUD, title: "Metal HUD", icon: "speedometer",
                isCore: false, defaultEnabled: true
            ) { AnyView(MetalHUDView()) },

            FeatureDefinition(
                id: .appLaunch, title: "启动监控", icon: "app.badge",
                isCore: false, defaultEnabled: true
            ) { AnyView(AppLaunchMonitorView().onAppear { AppLaunchMonitorService.shared.start() }) },

            FeatureDefinition(
                id: .folderMap, title: "目录映射", icon: "link",
                isCore: false, defaultEnabled: true
            ) { AnyView(FolderMapView()) },

            FeatureDefinition(
                id: .brew, title: "Homebrew", icon: "mug",
                isCore: false, defaultEnabled: true
            ) { AnyView(BrewView().onAppear { BrewService.shared.start() }) },

            FeatureDefinition(
                id: .cleanup, title: "垃圾清理", icon: "trash.fill",
                isCore: false, defaultEnabled: false
            ) { AnyView(CleanupView()) },

            FeatureDefinition(
                id: .launchAgent, title: "启动项", icon: "power",
                isCore: false, defaultEnabled: false
            ) { AnyView(LaunchAgentView()) },

            FeatureDefinition(
                id: .screenshot, title: "截图", icon: "camera.viewfinder",
                isCore: false, defaultEnabled: true
            ) { AnyView(ScreenshotView()) },

            FeatureDefinition(
                id: .scrollControl, title: "滚轮控制", icon: "computermouse",
                isCore: false, defaultEnabled: true
            ) { AnyView(ScrollControlView().onAppear { ScrollControlService.shared.refreshPermission() }) },

            FeatureDefinition(
                id: .rightClick, title: "右键增强", icon: "rectangle.on.folder",
                isCore: false, defaultEnabled: false
            ) { AnyView(RightClickView().onAppear { RightClickService.shared.publishMenuConfig() }) },
        ]
    }
}
