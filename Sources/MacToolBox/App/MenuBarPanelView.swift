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
                    metricsGrid
                    StatusSummaryInline(snapshot: service.snapshot)
                    quickActions
                }
                .padding(14)
            }
        }
        .frame(width: 320, height: 420)
        .background(Theme.windowBackground)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
               let image = NSImage(contentsOfFile: path) {
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
                PanelMetricCard(title: "温度", icon: "thermometer", value: service.snapshot.temperature != nil ? String(format: "%.0f°", service.snapshot.temperature!) : "—", color: .orange)
            }
            // 迷你趋势
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    TrendRow(title: "CPU", value: String(format: "%.1f%%", service.snapshot.cpuUsage),
                              values: service.snapshot.cpuHistory, color: Theme.accentStart, max: 100)
                    TrendRow(title: "温度", value: tempText(service.snapshot.temperature),
                              values: service.snapshot.tempHistory, color: .orange, max: nil)
                }
            }
        }
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 面板指标小卡

private struct PanelMetricCard: View {
    let title: String
    let icon: String
    let value: String
    let color: Color

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(color)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 状态摘要（内联版，供菜单栏面板用）

private struct StatusSummaryInline: View {
    let snapshot: SystemInfoService.SystemSnapshot

    var body: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var icon: String {
        let cpu = snapshot.cpuUsage
        let mem = snapshot.memoryUsage
        let temp = snapshot.temperature ?? 0
        if cpu > 90 || mem > 90 || temp > 90 { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var color: Color {
        let cpu = snapshot.cpuUsage
        let mem = snapshot.memoryUsage
        let temp = snapshot.temperature ?? 0
        if cpu > 90 || mem > 90 || temp > 90 { return .red }
        if cpu > 70 || mem > 70 || temp > 75 { return .orange }
        return .green
    }

    private var title: String {
        let cpu = snapshot.cpuUsage
        let mem = snapshot.memoryUsage
        let temp = snapshot.temperature ?? 0
        if cpu > 90 || mem > 90 || temp > 90 { return "负载偏高" }
        if cpu > 70 || mem > 70 || temp > 75 { return "运行正常 · 略有负载" }
        return "运行正常"
    }

    private var detail: String {
        "CPU \(String(format: "%.0f", snapshot.cpuUsage))% · 内存 \(String(format: "%.0f", snapshot.memoryUsage))%"
            + (snapshot.temperature != nil ? " · \(String(format: "%.0f", snapshot.temperature!))°C" : "")
    }
}
