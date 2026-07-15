import SwiftUI

/// 垃圾清理界面：按「系统 / 应用 / 上网」三类，每类下再按「应用」聚合为行，
/// 以应用为单位勾选/清理，从根本上把可选项从「每个文件」收敛到「每个应用」（几十行），
/// 选择计算从 O(N²) 降到 O(N)。展开应用行可查看具体文件（限 150 行）。
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
                if service.isScanning && service.groupsByCategory.isEmpty {
                    scanningPlaceholder
                } else {
                    categoryCards
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
            subtitle: "按应用聚合 · 选择即清理该应用全部垃圾"
        ) {
            if service.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 操作区

    private var actionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        selected.removeAll()
                        Task { await service.scan() }
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(service.isScanning || service.isCleaning)

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

    // MARK: - 分类卡片

    private var categoryCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "按应用清理", icon: "doc.on.doc")
                Spacer()
                Text("共 \(service.items.count) 项 · \(formatBytes(service.totalSize))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(CleanupCategory.allCases) { category in
                CategoryCard(
                    category: category,
                    groups: service.groupsByCategory[category] ?? [],
                    selected: $selected
                )
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

// MARK: - 单个分类卡片

private struct CategoryCard: View {
    let category: CleanupCategory
    let groups: [CleanupGroup]
    @Binding var selected: Set<URL>

    // 该类别全部成员 URL 集合（O(组大小) 构建一次/渲染）。
    private var categoryURLSet: Set<URL> { Set(groups.flatMap { $0.urlSet }) }
    private var selectedInCategory: Set<URL> { selected.intersection(categoryURLSet) }
    private var allSelected: Bool { !categoryURLSet.isEmpty && selectedInCategory == categoryURLSet }
    private var someSelected: Bool { !selectedInCategory.isEmpty && !allSelected }

    private var totalBytes: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(categoryColor.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: category.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(categoryColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            Text("\(groups.count) 个应用")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("\(groups.reduce(0) { $0 + $1.count }) 项")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Text(formatBytes(totalBytes))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)

                    Button {
                        toggleCategorySelection()
                    } label: {
                        Image(systemName: selectionIcon)
                            .font(.system(size: 18))
                            .foregroundStyle(selectionColor)
                    }
                    .buttonStyle(.borderless)
                    .disabled(groups.isEmpty)
                }
                .padding(12)

                if !groups.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            AppRow(group: group, selected: $selected)
                            if group.id != groups.last?.id {
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

    private var categoryColor: Color {
        switch category {
        case .system: return .orange
        case .application: return .blue
        case .internet: return .green
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

    private func toggleCategorySelection() {
        if allSelected {
            selected.subtract(categoryURLSet)
        } else {
            selected.formUnion(categoryURLSet)
        }
    }
}

// MARK: - 单个应用行

private struct AppRow: View {
    let group: CleanupGroup
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
            // 应用标题行
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: group.category.icon)
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
                        toggleGroupSelection()
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

    private func toggleGroupSelection() {
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
