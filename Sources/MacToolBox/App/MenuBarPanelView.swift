import SwiftUI

/// 菜单栏弹出面板：只展示核心信息
/// - 顶部：应用标识 + 打开主窗口
/// - 核心指标总览：CPU / 内存 / 网速 / 温度 四卡 + 迷你趋势
/// - 状态摘要：一句话健康状态
/// - 快捷操作：仅已启用功能的入口（由 FeatureManager 驱动）
struct MenuBarPanelView: View {
    @ObservedObject private var service = SystemInfoService.shared
    @StateObject private var features = FeatureManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    heroStatus
                    metricsGrid
                    Divider().padding(.horizontal, 4)
                    trendCenterpiece
                    quickActions
                }
                .padding(14)
            }
        }
        .frame(width: 340, height: 470)
        .background(VisualEffectView(material: .popover))
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            if let image = IconCache.appIcon {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("MacToolBox")
                    .font(.system(size: 14, weight: .semibold))
                Text("系统概览")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                (NSApplication.shared.delegate as? AppDelegate)?.showMainWindow()
            } label: {
                Label("主窗口", systemImage: "macwindow")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accentStart)
            .controlSize(.small)
            .help("打开完整主窗口")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - 核心指标网格

    private var metricsGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                PanelMetricCard(title: "CPU", icon: "cpu", value: "\(String(format: "%.0f", service.snapshot.cpuUsage))%", color: Theme.accentStart)
                PanelMetricCard(title: "内存", icon: "memorychip", value: "\(String(format: "%.0f", service.snapshot.memoryUsage))%", color: Theme.accentEnd)
            }
            HStack(spacing: 10) {
                PanelMetricCard(title: "网速", icon: "arrow.down.circle.fill", value: formatRateShort(service.snapshot.networkDown), color: .blue)
                PanelMetricCard(title: "温度", icon: "thermometer", value: service.snapshot.temperature.map { String(format: "%.0f°", $0) } ?? "—", color: .orange)
            }
        }
    }

    // MARK: - 状态横幅（彩色渐变底 + 白字，气泡视觉焦点）

    private var heroStatus: some View {
        let s = panelStatusInfo(service.snapshot)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // 图标光晕圆
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.25))
                        .frame(width: 36, height: 36)
                    Image(systemName: s.icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(s.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .fill(
                    LinearGradient(
                        colors: bannerGradient(for: s.color),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: s.color.opacity(0.25), radius: 8, y: 4)
        )
    }

    /// 根据状态色返回渐变色组
    private func bannerGradient(for statusColor: Color) -> [Color] {
        if statusColor == .red { return [Color.red.opacity(0.85), Color.orange.opacity(0.75)] }
        if statusColor == .orange { return [Color.orange.opacity(0.8), Color.yellow.opacity(0.65)] }
        // 默认正常态：品牌蓝→青渐变
        return [Theme.accentStart.opacity(0.88), Theme.accentEnd.opacity(0.78)]
    }

    // MARK: - 趋势画布（沉浸式图表区域）

    private var trendCenterpiece: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentStart)
                Text("实时趋势")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer()
                Text(String(format: "%.1f%%", service.snapshot.cpuUsage))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.accentStart)
                    .contentTransition(.numericText())
            }

            // CPU 趋势
            TrendRow(
                title: "CPU",
                value: String(format: "%.1f%%", service.snapshot.cpuUsage),
                values: service.snapshot.cpuHistory,
                color: Theme.accentStart, max: 100
            )
            .frame(height: 50)

            // 温度趋势
            TrendRow(
                title: "温度",
                value: tempText(service.snapshot.temperature),
                values: service.snapshot.tempHistory,
                color: .orange, max: nil
            )
            .frame(height: 50)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor),
                            Color(nsColor: .controlBackgroundColor).opacity(0.7),
                            Theme.accentStart.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusCard)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
    }

    // MARK: - 快捷操作（仅已启用功能）

    private var quickActions: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "快捷操作", icon: "bolt")
                let quick = features.enabledDefinitions.filter { $0.id != .overview }
                if quick.isEmpty {
                    Text("未启用任何扩展功能")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(quick) { def in
                            panelButton(def.title, def.icon) {
                                (NSApplication.shared.delegate as? AppDelegate)?.reveal(feature: def.id)
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    panelButton("偏好设置", "gearshape") {
                        (NSApplication.shared.delegate as? AppDelegate)?.openPreferences()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func panelButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        PanelActionButton(title: title, icon: icon, action: action)
    }
}

// MARK: - 面板操作按钮（带悬停反馈）

private struct PanelActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(Theme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).stroke(Theme.cardBorder, lineWidth: 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(Color.primary.opacity(hovered ? 0.05 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - 面板指标药丸（圆形图标底 + 左色条区分类型）

private struct PanelMetricCard: View {
    let title: String
    let icon: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            // 左色条（3px）
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
            HStack(spacing: 10) {
                // 圆形图标底
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.35), value: value)
                }
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(Theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
    }
}

// MARK: - 状态摘要计算（供气泡英雄区使用）

private func panelStatusInfo(_ snapshot: SystemInfoService.SystemSnapshot)
    -> (icon: String, color: Color, title: String, detail: String)
{
    let cpu = snapshot.cpuUsage
    let mem = snapshot.memoryUsage
    let temp = snapshot.temperature ?? 0
    let detail = "CPU \(String(format: "%.0f", cpu))% · 内存 \(String(format: "%.0f", mem))%"
        + (temp > 0 ? " · \(String(format: "%.0f", temp))°C" : "")

    if cpu > 90 || mem > 90 || temp > 90 {
        return ("exclamationmark.triangle.fill", .red, "负载偏高", detail)
    }
    if cpu > 70 || mem > 70 || temp > 75 {
        return ("exclamationmark.circle.fill", .orange, "运行正常 · 略有负载", detail)
    }
    return ("checkmark.circle.fill", .green, "运行正常", detail)
}
