import SwiftUI

/// 垃圾清理界面（照 Clean-Me 风格）：按「来源文件夹」聚合，基础（用户级）/高级（系统级）分离，
/// 每个来源下按应用聚合为行，展开可见具体文件。系统级来源标锁并提示需管理员权限。
struct CleanupView: View {
    @ObservedObject private var service = CleanupService.shared
    @State private var selected = Set<URL>()
    @State private var showErrors = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                actionCard
                if !service.lastErrors.isEmpty { errorCard }
                if service.isScanning && service.items.isEmpty {
                    scanningPlaceholder
                } else if sections.isEmpty {
                    emptyCard
                } else {
                    sourceCards
                }
                if service.lastCleanedBytes > 0 { resultSummary }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .onAppear {
            service.start()
            applyDefaultIfNeeded()
        }
        .onChange(of: service.items.count) { _ in
            applyDefaultIfNeeded()
        }
    }

    private func applyDefaultIfNeeded() {
        if !service.items.isEmpty && selected.isEmpty {
            selected = service.defaultSelection()
        }
    }

    // MARK: - 头部

    private var headerCard: some View {
        TabHeaderCard(
            icon: "trash.fill",
            title: "垃圾清理",
            subtitle: "照 Clean-Me 思路按来源聚合 · 只清内容不删目录"
        ) {
            if service.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    selected.removeAll()
                    Task { await service.scan() }
                } label: {
                    Text("重新扫描")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accentStart)
                .disabled(service.isCleaning)
            }
        }
    }

    // MARK: - 操作区

    private var actionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        selected = service.defaultSelection()
                    } label: {
                        Label("智能选择", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(service.isScanning || service.isCleaning || service.items.isEmpty)

                    Button {
                        Task { await service.clean(selected) }
                    } label: {
                        Label("清理选中", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStart)
                    .disabled(selected.isEmpty || service.isCleaning)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("已选 \(selected.count) 项")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(formatBytes(service.selectedBytes(selected)))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.accentStart)
                    }
                }

                if service.isScanning || service.isCleaning {
                    progressBar
                }
            }
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if service.isCleaning {
                let total = max(service.cleanProgress.total, 1)
                let value = Double(service.cleanProgress.current) / Double(total)
                ProgressView(value: value) {
                    Text("清理中 \(service.cleanProgress.current) / \(service.cleanProgress.total)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .progressViewStyle(.linear)
            } else if service.isScanning {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                Text("扫描中…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scanningPlaceholder: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在扫描垃圾文件…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("已发现 \(service.items.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyCard: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text("未发现可清理的垃圾文件。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 错误提示

    private var errorCard: some View {
        Card {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("部分项目未能删除（\(service.lastErrors.count)）")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("查看") { showErrors = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Theme.accentStart)
            }
        }
        .sheet(isPresented: $showErrors) {
            ErrorSheet(errors: service.lastErrors)
        }
    }

    // MARK: - 按来源分组

    private var sourceCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "按来源清理", icon: "folder")
                Spacer()
                Text("共 \(service.items.count) 项 · 可释放 \(formatBytes(service.totalSize))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(sections) { section in
                SourceCard(section: section, selected: $selected)
            }
        }
    }

    private var resultSummary: some View {
        Card {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accentEnd)
                Text("本次清理释放 \(formatBytes(service.lastCleanedBytes))")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
        }
    }

    // MARK: - 聚合（按来源）

    private var sections: [SourceSection] {
        let grouped = Dictionary(grouping: service.items, by: { $0.source })
        return grouped.map { src, items in
            SourceSection(source: src, needsAdmin: items.first?.needsAdmin ?? false, items: items)
        }.sorted { a, b in
            // 基础（用户级）来源在前，系统级在后；同级按大小降序。
            if a.needsAdmin != b.needsAdmin { return !a.needsAdmin }
            return a.totalSize > b.totalSize
        }
    }

    // MARK: - 错误详情 Sheet

    private struct ErrorSheet: View {
        let errors: [URL: String]
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("删除失败明细")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(errors.keys), id: \.self) { url in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.path)
                                    .font(.system(size: 12, weight: .medium))
                                    .textSelection(.enabled)
                                Text(errors[url] ?? "")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                }
                Button("关闭") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStart)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
            .frame(width: 460, height: 360)
        }
    }
}

// MARK: - 来源聚合结构

private struct SourceSection: Identifiable {
    let source: String
    let needsAdmin: Bool
    let items: [CleanupItem]
    var id: String { source }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    var appGroups: [AppGroup] {
        let g = Dictionary(grouping: items, by: { $0.appName })
        return g.map { AppGroup(appName: $0.key, items: $0.value) }
            .sorted { $0.totalSize > $1.totalSize }
    }
}

private struct AppGroup: Identifiable {
    let appName: String
    let items: [CleanupItem]
    var id: String { appName.isEmpty ? "__system__" : appName }
    var count: Int { items.count }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var urlSet: Set<URL> { Set(items.map { $0.url }) }
    var displayName: String { appName.isEmpty ? "系统文件" : appName }
}

// MARK: - 单个来源卡片

private struct SourceCard: View {
    let section: SourceSection
    @Binding var selected: Set<URL>
    @State private var isExpanded = true

    private var sectionURLSet: Set<URL> { Set(section.items.map { $0.url }) }
    private var selectedInSection: Set<URL> { selected.intersection(sectionURLSet) }
    private var allSelected: Bool { !sectionURLSet.isEmpty && selectedInSection == sectionURLSet }
    private var someSelected: Bool { !selectedInSection.isEmpty && !allSelected }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                // 标题行（始终显示，点击可折叠）
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill((section.needsAdmin ? Color.orange : Theme.accentStart).opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: section.needsAdmin ? "lock.fill" : "folder.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(section.needsAdmin ? .orange : Theme.accentStart)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(section.source)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                if section.needsAdmin {
                                    Text("需管理员")
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.15))
                                        .foregroundStyle(.orange)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            Text("\(section.items.count) 项 · \(section.appGroups.count) 个来源")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(formatBytes(section.totalSize))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)

                        // 折叠箭头
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20)

                        // 全选按钮
                        Button {
                            toggleSection()
                        } label: {
                            Image(systemName: selectionIcon)
                                .font(.system(size: 18))
                                .foregroundStyle(selectionColor)
                        }
                        .buttonStyle(.borderless)
                        .disabled(section.items.isEmpty)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 展开内容：应用子列表
                if isExpanded && !section.appGroups.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(section.appGroups) { group in
                            AppRow(group: group, selected: $selected)
                            if group.id != section.appGroups.last?.id {
                                Divider().padding(.leading, 50)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var selectionIcon: String {
        if allSelected { return "checkmark.square.fill" }
        if someSelected { return "minus.square.fill" }
        return "square"
    }

    private var selectionColor: Color {
        allSelected || someSelected ? Theme.accentStart : .secondary
    }

    private func toggleSection() {
        if allSelected {
            selected.subtract(sectionURLSet)
        } else {
            selected.formUnion(sectionURLSet)
        }
    }
}

// MARK: - 单个应用行

private struct AppRow: View {
    let group: AppGroup
    @Binding var selected: Set<URL>

    @State private var isExpanded: Bool = false

    private var selectedInGroup: Set<URL> { selected.intersection(group.urlSet) }
    private var allSelected: Bool { !group.urlSet.isEmpty && selectedInGroup == group.urlSet }
    private var someSelected: Bool { !selectedInGroup.isEmpty && !allSelected }

    private var displayedItems: [CleanupItem] {
        Array(group.items.prefix(150))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            Text("\(group.count) 项")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            if someSelected {
                                Text("· 已选 \(selectedInGroup.count)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.accentStart)
                            }
                        }
                    }

                    Spacer()

                    Text(formatBytes(group.totalSize))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)

                    Button {
                        toggleGroup()
                    } label: {
                        Image(systemName: selectionIcon)
                            .font(.system(size: 17))
                            .foregroundStyle(selectionColor)
                    }
                    .buttonStyle(.borderless)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(displayedItems) { item in
                        ItemRow(item: item, selected: $selected)
                        if item.id != displayedItems.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                    if group.count > displayedItems.count {
                        Text("还有 \(group.count - displayedItems.count) 项未显示，清理以应用为单位即可")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
        }
    }

    private var selectionIcon: String {
        if allSelected { return "checkmark.square.fill" }
        if someSelected { return "minus.square.fill" }
        return "square"
    }

    private var selectionColor: Color {
        allSelected || someSelected ? Theme.accentStart : .secondary
    }

    private func toggleGroup() {
        if allSelected {
            selected.subtract(group.urlSet)
        } else {
            selected.formUnion(group.urlSet)
        }
    }
}

// MARK: - 单行文件项

private struct ItemRow: View {
    let item: CleanupItem
    @Binding var selected: Set<URL>

    var body: some View {
        Button {
            if selected.contains(item.url) {
                selected.remove(item.url)
            } else {
                selected.insert(item.url)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected.contains(item.url) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(selected.contains(item.url) ? Theme.accentStart : .secondary)
                    .frame(width: 18)

                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.kind)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(item.path)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(formatBytes(item.size))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
