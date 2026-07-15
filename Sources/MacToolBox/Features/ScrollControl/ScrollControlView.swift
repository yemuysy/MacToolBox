import SwiftUI

/// 滚轮控制页：主开关 + 反向 + 平滑 + 触控板豁免 + 辅助功能权限引导。
/// 参照 Mos，鼠标滚轮方向自然化与平滑滚动；触控板保持系统原生手感。
struct ScrollControlView: View {
    @StateObject private var service = ScrollControlService.shared

    private var config: ConfigStore.ScrollControlConfig { service.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !service.accessibilityGranted {
                    permissionCard
                }
                reverseCard
                smoothCard
                trackpadCard
                tipCard
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .onAppear { service.refreshPermission() }
    }

    // MARK: - 头部（主开关 + 状态）

    private var header: some View {
        TabHeaderCard(
            icon: "computermouse",
            title: "滚轮控制",
            subtitle: "鼠标滚轮方向反转与平滑滚动，触控板自动豁免"
        ) {
            HStack(spacing: 10) {
                StatusPill(
                    text: statusText,
                    color: statusColor
                )
                Toggle("", isOn: Binding(
                    get: { config.enabled },
                    set: { service.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!service.accessibilityGranted)
            }
        }
    }

    private var statusText: String {
        if !service.accessibilityGranted { return "未授权" }
        if service.running { return "运行中" }
        return config.enabled ? "已停用" : "已关闭"
    }

    private var statusColor: Color {
        if !service.accessibilityGranted { return .orange }
        return service.running ? .green : .secondary
    }

    // MARK: - 权限引导

    private var permissionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "需要辅助功能权限", icon: "lock.shield")
                Text("滚轮拦截依赖「辅助功能」权限。请授权后再开启拦截；未授权时主开关不可用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        service.requestAccessibility()
                    } label: {
                        Label("申请授权", systemImage: "checkmark.shield")
                    }
                    .controlSize(.small)
                    Button {
                        service.openAccessibilitySettings()
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                    }
                    .controlSize(.small)
                    Button {
                        service.refreshPermission()
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 反向

    private var reverseCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "方向反转", icon: "arrow.up.arrow.down")
                toggleRow("纵向反向", icon: "arrow.up.arrow.down",
                          desc: "向下滚动内容向下（自然滚动方向）",
                          isOn: Binding(
                            get: { config.reverseVertical },
                            set: { v in service.update { $0.reverseVertical = v } }))
                Divider().padding(.leading, 4)
                toggleRow("横向反向", icon: "arrow.left.arrow.right",
                          desc: "反转横向滚动方向",
                          isOn: Binding(
                            get: { config.reverseHorizontal },
                            set: { v in service.update { $0.reverseHorizontal = v } }))
            }
        }
    }

    // MARK: - 平滑

    private var smoothCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "平滑滚动", icon: "wind")
                toggleRow("启用平滑滚动", icon: "wind",
                          desc: "把一次滚动插值为多帧，滚动更顺滑",
                          isOn: Binding(
                            get: { config.smooth },
                            set: { v in service.update { $0.smooth = v } }))
                if config.smooth {
                    Divider().padding(.leading, 4)
                    sliderRow(
                        "平滑度",
                        value: Binding(
                            get: { config.smoothStep },
                            set: { v in service.update { $0.smoothStep = v } }),
                        range: 0.1...0.9,
                        format: String(format: "%.2f", config.smoothStep),
                        hint: "越大越跟手，越小越顺滑"
                    )
                    sliderRow(
                        "加速度",
                        value: Binding(
                            get: { config.smoothSpeed },
                            set: { v in service.update { $0.smoothSpeed = v } }),
                        range: 1...10,
                        format: String(format: "%.1f×", config.smoothSpeed),
                        hint: "滚动距离放大倍率"
                    )
                }
            }
        }
    }

    // MARK: - 触控板豁免

    private var trackpadCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "触控板", icon: "rectangle.and.hand.point.up.left")
                toggleRow("触控板豁免", icon: "hand.draw",
                          desc: "自动识别并跳过触控板，保持系统原生手感（推荐开启）",
                          isOn: Binding(
                            get: { config.excludeTrackpad },
                            set: { v in service.update { $0.excludeTrackpad = v } }))
            }
        }
    }

    private var tipCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "说明", icon: "info.circle")
                Text("• 仅对鼠标滚轮生效；触控板事件默认原样放行。\n• 若滚动异常，多次自动重启失败会进入冷却，关闭再开启可恢复。\n• 需要辅助功能权限；系统更新后可能需重新授权。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 复用行

    private func toggleRow(
        _ title: String,
        icon: String,
        desc: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(desc).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(format)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accentStart)
            }
            Slider(value: value, in: range)
            Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
