import SwiftUI

/// 概览页（Dashboard）：聚合核心系统指标 + 状态摘要 + 快捷入口
struct OverviewView: View {
    @ObservedObject private var service = SystemInfoService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 顶部 4 个核心指标卡（统一高度）
                HStack(alignment: .center, spacing: 12) {
                    UsageCard(
                        title: "CPU",
                        icon: "cpu",
                        percent: service.snapshot.cpuUsage,
                        color: Theme.accentStart
                    )
                    .frame(maxHeight: .infinity)

                    UsageCard(
                        title: "内存",
                        icon: "memorychip",
                        percent: service.snapshot.memoryUsage,
                        color: Theme.accentEnd
                    )
                    .frame(maxHeight: .infinity)

                    NetworkCard(down: service.snapshot.networkDown, up: service.snapshot.networkUp)
                        .frame(maxHeight: .infinity)

                    TempCard(temperature: service.snapshot.temperature)
                        .frame(maxHeight: .infinity)
                }
                .frame(height: 76)

                // 实时趋势
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "实时趋势", icon: "chart.xyaxis.line")
                        TrendRow(title: "CPU 使用率", value: String(format: "%.1f%%", service.snapshot.cpuUsage),
                                  values: service.snapshot.cpuHistory, color: Theme.accentStart, max: 100)
                        TrendRow(title: "内存使用率", value: String(format: "%.1f%%", service.snapshot.memoryUsage),
                                  values: service.snapshot.memHistory, color: Theme.accentEnd, max: 100)
                        TrendRow(title: "下载速率", value: formatRate(service.snapshot.networkDown),
                                  values: service.snapshot.netDownHistory, color: .blue, max: nil)
                        TrendRow(title: "温度", value: tempText(service.snapshot.temperature),
                                  values: service.snapshot.tempHistory, color: .orange, max: nil)
                    }
                }

                // 内存详情
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "内存详情", icon: "memorychip")
                        HStack(spacing: 12) {
                            memoryStatView("已用", service.snapshot.memoryUsed, Theme.accentStart)
                            Divider().frame(height: 24)
                            memoryStatView("总计", service.snapshot.memoryTotal, Theme.accentEnd)
                            Divider().frame(height: 24)
                            memoryStatView("可用", service.snapshot.memoryTotal - service.snapshot.memoryUsed, .secondary)
                        }
                    }
                }

                // 硬件信息
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "硬件信息", icon: "cpu")
                        VStack(alignment: .leading, spacing: 7) {
                            InfoRow(label: "型号", value: service.snapshot.modelIdentifier)
                            InfoRow(label: "序列号", value: service.snapshot.serialNumber)
                            InfoRow(label: "系统版本", value: "macOS \(service.snapshot.osVersion)")
                            InfoRow(label: "电池循环", value: "\(service.snapshot.batteryCycleCount) 次")
                            InfoRow(label: "电池健康", value: service.snapshot.batteryHealth)
                            InfoRow(label: "开机时长", value: formatUptime(service.snapshot.uptimeSeconds))
                        }
                    }
                }

                // CPU 温度核心明细（来自 SystemInfoService：最热核心 / 平均）
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "CPU 温度", icon: "thermometer.medium")
                        HStack(spacing: 12) {
                            tempStat("最热核心", service.snapshot.temperatureHottest ?? 0)
                            Divider().frame(height: 24)
                            tempStat("平均", service.snapshot.temperature ?? 0)
                            Spacer()
                        }
                    }
                }

                // 磁盘概览
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "磁盘", icon: "externaldrive")
                        if service.snapshot.disks.isEmpty {
                            Text("读取中…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(service.snapshot.disks) { disk in
                                    DiskUsageRow(disk: disk)
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - 温度小格

    private func tempStat(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value > 0 ? String(format: "%.1f°C", value) : "—")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
        }
    }

    // MARK: - Helpers

    private func formatUptime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(mins) 分钟" }
        return "\(mins) 分钟"
    }
}
