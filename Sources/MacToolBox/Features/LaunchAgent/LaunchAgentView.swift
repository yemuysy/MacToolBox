import SwiftUI

/// 启动项管理界面：列出 ~/Library/LaunchAgents 中的 plist，
/// 支持「备份禁用」（移入 Backup 目录）与「恢复」。
struct LaunchAgentView: View {
    @ObservedObject private var service = LaunchAgentService.shared
    @State private var searchText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                listCard
                Spacer()
            }
            .padding(14)
        }
        .onAppear { service.start() }
    }

    private var headerCard: some View {
        TabHeaderCard(
            icon: "power",
            title: "启动项",
            subtitle: "LaunchAgents · 备份禁用可一键恢复"
        ) {
            if service.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    service.refresh()
                } label: {
                    Text("刷新")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accentStart)
            }
        }
    }

    private var listCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "登录项", icon: "list.bullet")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("搜索服务名 / 路径", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(6)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                let list = filtered
                if list.isEmpty {
                    Text(service.items.isEmpty ? "未找到任何 LaunchAgent。" : "无匹配项。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(list) { item in
                            row(item)
                            if item.id != list.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.system(size: 13, weight: .medium))
                    if item.runAtLoad {
                        Text("开机自启")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.accentStart.opacity(0.12))
                            .foregroundStyle(Theme.accentStart)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if item.disabled {
                        Text("已禁用")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(item.programArguments.joined(separator: " ") )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()

            if item.disabled {
                Button {
                    service.restore(fileName: item.fileURL.lastPathComponent)
                } label: {
                    Text("恢复")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accentEnd)
            } else {
                Button {
                    service.disable(item)
                } label: {
                    Text("禁用")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var filtered: [LaunchItem] {
        guard !searchText.isEmpty else { return service.items }
        return service.items.filter {
            $0.label.localizedCaseInsensitiveContains(searchText)
                || $0.programArguments.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
        }
    }
}
