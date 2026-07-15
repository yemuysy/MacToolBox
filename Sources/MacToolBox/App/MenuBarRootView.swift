import SwiftUI

/// 主窗口根视图：左侧图标侧边栏 + 主内容区。
/// - 侧边栏仅渲染「已启用」的功能（由 FeatureManager 驱动），关闭某功能即从主界面移除入口并避免其实例化。
/// - 内容区按 FeatureID 切换，未启用功能显示占位提示。
struct MenuBarRootView: View {
    @StateObject private var features = FeatureManager.shared
    @State private var selected: FeatureID = FeatureManager.shared.landing

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
        .background(Theme.windowBackground)
        .onReceive(features.$enabledIDs) { _ in
            // 当前功能被关闭时回退到着陆功能
            if !features.isEnabled(selected) { selected = features.landing }
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
                    SidebarButton(def: def, selected: $selected)
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
        .background(Theme.cardBackground.opacity(0.5))
    }

    // MARK: - 主内容区

    @ViewBuilder
    private var contentArea: some View {
        Group {
            if let view = features.content(for: selected) {
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
        .id(selected) // 选中变化时整体重建，确保 onAppear 正确触发
    }

    /// 返回一个选中指定功能的副本（供 AppDelegate.reveal 切换侧边栏）
    func selecting(_ feature: FeatureID) -> MenuBarRootView {
        let copy = self
        copy.selected = feature
        return copy
    }

    // MARK: - 应用图标

    private var appIcon: some View {
        Group {
            if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
               let image = NSImage(contentsOfFile: path) {
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
    var isSelected: Bool { selected == def.id }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selected = def.id
            }
        } label: {
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
            .contentShape(Rectangle())
            .background(
                Theme.accentGradient
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .opacity(isSelected ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
    }
}
