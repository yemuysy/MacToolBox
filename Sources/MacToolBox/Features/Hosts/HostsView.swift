import SwiftUI

/// hosts 管理视图（参考 SwitchHosts）。
/// 左侧方案列表（含只读「系统当前」项与激活徽章），右侧编辑器 / 只读视图，工具栏支持应用 / 复制 / 删除 / 导入 / 导出。
struct HostsView: View {
    @ObservedObject private var service = HostsService.shared
    @State private var selectedID: String = HostScheme.systemID

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerCard
            HStack(alignment: .top, spacing: 14) {
                schemeListCard
                editorCard
            }
            if let msg = service.lastMessage {
                messageBanner(msg)
            }
            Spacer(minLength: 0)
        }
        .onAppear { service.start() }
        .onChange(of: service.schemes) { _ in
            // 删除当前选中项后回退到系统项
            if selectedID != HostScheme.systemID,
               !service.schemes.contains(where: { $0.id == selectedID }) {
                selectedID = HostScheme.systemID
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        TabHeaderCard(
            icon: "globe",
            title: "Hosts 管理",
            subtitle: "多套方案，一键切换系统 /etc/hosts。"
        ) {
            Button {
                service.start()
            } label: {
                Text("刷新")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Theme.accentStart)
        }
    }

    // MARK: - 左侧方案列表

    private var schemeListCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "方案", icon: "list.bullet")

                // 系统当前（只读）
                systemRow

                if !service.schemes.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(service.schemes) { scheme in
                        SchemeRow(
                            scheme: scheme,
                            isSelected: selectedID == scheme.id,
                            isActive: service.activeSchemeID == scheme.id
                        ) {
                            selectedID = scheme.id
                        }
                        .contextMenu {
                            Button("复制") { service.duplicateScheme(id: scheme.id) }
                            Button("导出…") { exportScheme(scheme) }
                            Divider()
                            Button("删除", role: .destructive) { service.deleteScheme(id: scheme.id) }
                        }
                    }
                }

                Button {
                    let created = service.createScheme()
                    selectedID = created.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("新建方案")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accentStart)
            }
        }
        .frame(width: 232)
    }

    private var systemRow: some View {
        let isActive = selectedID == HostScheme.systemID
        return HStack(spacing: 8) {
            Image(systemName: "gear")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("系统当前")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text("/etc/hosts")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if service.activeSchemeID == nil {
                StatusPill(text: "生效中", color: .green)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(isActive ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
        )
        .onTapGesture { selectedID = HostScheme.systemID }
    }

    // MARK: - 右侧编辑器

    private var editorCard: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                Divider()
                if selectedID == HostScheme.systemID {
                    readOnlySystem
                } else {
                    editor
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if selectedID == HostScheme.systemID {
                Text("系统当前 /etc/hosts（只读）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let scheme = selectedScheme {
                TextField("方案名称", text: nameBinding)
                    .font(.system(size: 13, weight: .semibold))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Spacer()

                Button {
                    service.duplicateScheme(id: scheme.id)
                } label: { Image(systemName: "plus.square.on.square").font(.system(size: 13)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("复制方案")

                Button {
                    importFile()
                } label: { Image(systemName: "square.and.arrow.down").font(.system(size: 13)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("从文件导入")

                Button {
                    exportScheme(scheme)
                } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 13)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("导出到文件")

                Button {
                    service.deleteScheme(id: scheme.id)
                } label: { Image(systemName: "trash").font(.system(size: 13)) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help("删除方案")

                Button {
                    service.applyScheme(scheme)
                } label: {
                    Label("应用", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.accentStart)
                .help("写入 /etc/hosts（需管理员密码）")
            }
        }
    }

    private var editor: some View {
        HostsTextView(text: contentBinding, isEditable: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(Theme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .stroke(Theme.cardBorder, lineWidth: 1))
            )
    }

    private var readOnlySystem: some View {
        HostsTextView(text: .constant(service.systemHosts), isEditable: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(Theme.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .stroke(Theme.cardBorder, lineWidth: 1))
            )
    }

    private func messageBanner(_ msg: (text: String, isError: Bool)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: msg.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 11))
            Text(msg.text)
                .font(.system(size: 11))
            Spacer()
            Button { service.lastMessage = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(msg.isError ? Color.red : Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background((msg.isError ? Color.red : Color.orange).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 绑定与动作

    private var selectedScheme: HostScheme? {
        service.schemes.first(where: { $0.id == selectedID })
    }

    private var contentBinding: Binding<String> {
        Binding(
            get: {
                if selectedID == HostScheme.systemID { return service.systemHosts }
                return service.schemes.first(where: { $0.id == selectedID })?.content ?? ""
            },
            set: { service.updateScheme(id: selectedID, content: $0) }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { service.schemes.first(where: { $0.id == selectedID })?.name ?? "" },
            set: { service.updateScheme(id: selectedID, name: $0) }
        )
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.begin { result in
            if result == .OK, let url = panel.url {
                service.importFromFile(url)
            }
        }
    }

    private func exportScheme(_ scheme: HostScheme) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(scheme.name).hosts"
        panel.allowedContentTypes = [.plainText]
        panel.begin { result in
            if result == .OK, let url = panel.url {
                service.exportScheme(scheme, to: url)
            }
        }
    }
}

// MARK: - 方案单行

private struct SchemeRow: View {
    let scheme: HostScheme
    let isSelected: Bool
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white : Theme.accentStart)
                .frame(width: 18)
            Text(scheme.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
            Spacer()
            if isActive {
                StatusPill(text: "生效中", color: .green)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
        )
        .onTapGesture { onSelect() }
    }
}
