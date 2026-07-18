import SwiftUI

/// 主窗口根视图：左侧图标侧边栏 + 主内容区。
/// - 侧边栏仅渲染「已启用」的功能（由 FeatureManager 驱动），关闭某功能即从主界面移除入口并避免其实例化。
/// - 内容区按 FeatureID 切换，未启用功能显示占位提示。
struct MenuBarRootView: View {
    @StateObject private var features = FeatureManager.shared
    /// 当前选中的侧栏功能：直接绑定到 FeatureManager.selectedFeature（共享单一真相来源），
    /// 避免 reveal 时重建整棵视图树（也修复了「跳转特定功能总落到概览」的 bug）。
    private var selection: Binding<FeatureID> { $features.selectedFeature }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentArea
        }
        .frame(
            minWidth: 760, idealWidth: 920, maxWidth: .infinity,
            minHeight: 560, idealHeight: 660, maxHeight: .infinity
        )
        .background(VisualEffectView(material: .windowBackground))
        .onReceive(features.$enabledIDs) { _ in
            // 当前功能被关闭时回退到着陆功能
            if !features.isEnabled(features.selectedFeature) { features.selectedFeature = features.landing }
        }
    }

    // MARK: - 左侧侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 品牌区
            HStack(spacing: 10) {
                appIcon
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacToolBox")
                        .font(.system(size: 14, weight: .semibold))
                    Text("系统工具箱")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().padding(.horizontal, 12)

            // 导航项（仅已启用功能）
            VStack(spacing: 4) {
                ForEach(features.enabledDefinitions) { def in
                    SidebarButton(def: def, selected: selection)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Spacer()

            // 底部：状态 + 收起到菜单栏
            VStack(spacing: 8) {
                Divider().padding(.horizontal, 12)
                HStack(spacing: 6) {
                    StatusPill(text: "运行中", color: .green)
                    Spacer()
                    Button {
                        (NSApplication.shared.delegate as? AppDelegate)?.hideMainWindow()
                    } label: {
                        Label("收起到菜单栏", systemImage: "menubar.rectangle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("收起主窗口，菜单栏图标仍然保留")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 200)
        .background(VisualEffectView(material: .sidebar))
    }

    // MARK: - 主内容区

    private var contentArea: some View {
        contentInner
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.22), value: features.selectedFeature)
    }

    @ViewBuilder
    private var contentInner: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 统一页面顶栏（图标徽章 + 标题 + 副标题），随选中功能切换
            if let def = features.definitions.first(where: { $0.id == features.selectedFeature }) {
                PageHeader(icon: def.icon, title: def.title, subtitle: pageSubtitle(for: def.id))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            }
            Group {
                if let view = features.content(for: features.selectedFeature) {
                    view
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("该功能已关闭")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Text("在「偏好设置 → 功能开关」中重新启用")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(features.selectedFeature) // 选中变化时整体重建，确保 onAppear 正确触发 + 配合淡入过渡
        .transition(.opacity)
    }

    /// 各功能页的副标题（统一补充「被设计」的层次感）
    private func pageSubtitle(for id: FeatureID) -> String {
        switch id {
        case .overview: return "系统实时状态一览"
        case .diskMount: return "挂载 / 卸载磁盘与卷"
        case .metalHUD: return "Metal 性能监控浮层"
        case .appLaunch: return "管理开机自启应用"
        case .folderMap: return "磁盘空间可视化"
        case .brew: return "Homebrew 包管理"
        case .scrollControl: return "滚轮增强与手势"
        case .rightClick: return "Finder 右键增强"
        case .cleanup: return "磁盘清理与空间管理"
        case .launchAgent: return "登录项管理"
        case .screenshot: return "截图与录屏"
        case .hosts: return "hosts 方案管理与一键切换"
        }
    }

    // MARK: - 应用图标

    private var appIcon: some View {
        Group {
            if let image = IconCache.appIcon {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Theme.accentGradient)
                    .padding(6)
            }
        }
    }
}

// MARK: - 侧边栏按钮

private struct SidebarButton: View {
    let def: FeatureDefinition
    @Binding var selected: FeatureID
    @State private var hovered = false
    var isSelected: Bool { selected == def.id }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: def.icon)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .frame(width: 20)
            Text(def.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            Spacer()
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Group {
                if isSelected {
                    Theme.accentGradient
                } else {
                    Color.primary.opacity(hovered ? 0.06 : 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selected = def.id
            }
        }
        .onHover { hovered = $0 }
    }
}
