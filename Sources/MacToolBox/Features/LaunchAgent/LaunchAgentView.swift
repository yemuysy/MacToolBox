import SwiftUI
import AppKit

/// 启动项管理界面（照 KnockKnock 思路，按作用域分组枚举多位置）。
/// - 用户级：备份禁用 / 恢复
/// - 系统级：App 内不可改，提供复制 launchctl 命令
/// - 系统锁定：仅展示
struct LaunchAgentView: View {
    @ObservedObject private var service = LaunchAgentService.shared
    @State private var searchText: String = ""
    @State private var collapsedScopes: Set<LaunchItemScope> = []

    /// 分组顺序：用户级在前，系统级、系统锁定在后。
    private let sectionOrder: [LaunchItemScope] = [.user, .system, .systemReadOnly]

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
            subtitle: "LaunchAgent / LaunchDaemon · 照 KnockKnock 枚举多位置"
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

                if filtered.isEmpty {
                    Text(service.items.isEmpty ? "未找到任何启动项。" : "无匹配项。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(sectionOrder, id: \.self) { scope in
                        let list = filtered.filter { $0.scope == scope }
                        if !list.isEmpty {
                            let collapsed = collapsedScopes.contains(scope)
                            // 可折叠分组头
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if collapsed { collapsedScopes.remove(scope) }
                                    else { collapsedScopes.insert(scope) }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: scopeIcon(scope))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.accentStart)
                                    SectionHeader(title: "\(scope.displayName)（\(list.count)）", icon: "")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if !collapsed {
                                VStack(spacing: 0) {
                                    ForEach(list) { item in
                                        row(item)
                                        if item.id != list.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                                .padding(.bottom, 8)
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
                    Image(systemName: item.kind.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
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
                    if item.scope != .user {
                        Text(item.scope.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(item.scope == .systemReadOnly ? Color.gray.opacity(0.18) : Color.orange.opacity(0.15))
                            .foregroundStyle(item.scope == .systemReadOnly ? Color.secondary : Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(item.programArguments.joined(separator: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()

            HStack(spacing: 8) {
                // 在 Finder 中定位
                Button {
                    reveal(item)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")

                if item.scope == .user {
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
                } else {
                    // 系统级/只读：复制 launchctl 命令
                    Button {
                        copyCommand(service.launchctlCommand(for: item, action: "unload"))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制 launchctl 命令到剪贴板")
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func scopeIcon(_ scope: LaunchItemScope) -> String {
        switch scope {
        case .user: return "person.circle"
        case .system: return "building.2"
        case .systemReadOnly: return "lock.shield"
        }
    }

    private var filtered: [LaunchItem] {
        guard !searchText.isEmpty else { return service.items }
        return service.items.filter {
            $0.label.localizedCaseInsensitiveContains(searchText)
                || $0.programArguments.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
        }
    }

    private func reveal(_ item: LaunchItem) {
        NSWorkspace.shared.selectFile(item.fileURL.path,
                                      inFileViewerRootedAtPath: item.fileURL.deletingLastPathComponent().path)
    }

    private func copyCommand(_ cmd: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
    }
}
