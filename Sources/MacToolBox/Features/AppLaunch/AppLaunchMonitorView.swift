import SwiftUI

/// 应用启动监听视图：实时显示新启动应用的 PID/路径/参数/环境变量
struct AppLaunchMonitorView: View {
    @ObservedObject private var service = AppLaunchMonitorService.shared
    @State private var selectedRecord: AppLaunchRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TabHeaderCard(
                icon: "app.badge",
                title: "启动监听",
                subtitle: "捕获应用启动事件并查看进程参数。",
                trailing: {
                    HStack(spacing: 8) {
                        StatusPill(text: "已捕获 \(service.records.count) 条", color: Theme.accentEnd)
                        Button {
                            service.clear()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .disabled(service.records.isEmpty)
                        .help("清空")
                    }
                }
            )

            listCard

            if let selected = selectedRecord {
                RecordDetail(record: selected)
            }

            Spacer()
        }
        .onAppear {
            service.start()
        }
    }

    // MARK: - 捕获列表

    private var listCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "捕获列表", icon: "list.bullet.rectangle")

                if service.records.isEmpty {
                    EmptyState(
                        icon: "hourglass",
                        title: "等待应用启动",
                        subtitle: "任何应用启动时，会在这里显示进程参数"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(service.records) { record in
                                RecordRow(record: record, isSelected: selectedRecord?.id == record.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedRecord = record
                                        }
                                    }
                            }
                        }
                    }
                    .frame(minHeight: 120)
                }
            }
        }
    }

}

// MARK: - 子视图

private struct RecordRow: View {
    let record: AppLaunchRecord
    let isSelected: Bool

    /// 时间格式化器静态缓存，避免每行每次重渲染都新建 DateFormatter
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isSelected ? Theme.accentStart.opacity(0.15) : Color.gray.opacity(0.10))
                    .frame(width: 30, height: 30)
                Image(systemName: "app")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accentStart : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(record.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("PID \(record.pid) · \(record.arguments.count) 个参数")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let path = record.executablePath {
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text(formatTime(record.launchedAt))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(isSelected ? Theme.accentStart.opacity(0.08) : Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Theme.accentStart.opacity(0.35) : Theme.cardBorder, lineWidth: 1)
        )
    }

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

private struct RecordDetail: View {
    let record: AppLaunchRecord

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Theme.accentEnd.opacity(0.12))
                            .frame(width: 32, height: 32)
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accentEnd)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(record.appName)
                            .font(.system(size: 13, weight: .semibold))
                        if let bundleId = record.bundleIdentifier {
                            Text(bundleId)
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "启动参数", icon: "list.bullet.rectangle")
                    if record.arguments.isEmpty {
                        Text("（无）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(record.arguments.enumerated()), id: \.offset) { _, arg in
                                    Text(arg)
                                        .font(.system(size: 10).monospaced())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color(nsColor: .textBackgroundColor))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
