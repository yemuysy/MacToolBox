import SwiftUI

/// Homebrew 操作视图：概览 + 更新/升级/清理 + 可更新列表 + 已安装列表
struct BrewView: View {
    @ObservedObject private var service = BrewService.shared

    @State private var searchText: String = ""
    @State private var listSegment: ListSegment = .formula
    @State private var pendingUninstall: BrewService.PkgInfo?
    @State private var showOutput: Bool = false

    @State private var showAllOutdated: Bool = false
    @State private var showAllInstalled: Bool = false
    @State private var installText: String = ""
    @State private var uninstallDependentCount: Int = 0
    private let outdatedLimit = 10
    private let installedLimit = 20

    enum ListSegment: String, CaseIterable, Identifiable {
        case formula = "命令行"
        case cask = "应用"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                overviewCard
                actionCard
                if !service.outdated.isEmpty {
                    outdatedCard
                }
                installedCard
                Spacer(minLength: 20)
            }
            .padding(14)
        }
        .onAppear { service.start() }
        .onChange(of: listSegment) { _ in
            showAllInstalled = false
            showAllOutdated = false
            searchText = ""
        }
        .alert(
            "确认卸载",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingUninstall = nil }
            Button("卸载", role: .destructive) {
                if let pkg = pendingUninstall {
                    service.runUninstall(name: pkg.name, isCask: pkg.isCask)
                }
                pendingUninstall = nil
            }
        } message: {
            if let pkg = pendingUninstall {
                if uninstallDependentCount > 0 {
                    Text("\(pkg.name) 被 \(uninstallDependentCount) 个已安装包依赖。卸载后这些包可能无法正常工作。确定继续吗？")
                } else {
                    Text("确定要卸载 \(pkg.name)（\(pkg.isCask ? "应用" : "命令行工具")）吗？此操作不可撤销。")
                }
            }
        }
        .sheet(isPresented: $showOutput) {
            outputSheet
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        TabHeaderCard(
            icon: "mug",
            title: "Homebrew",
            subtitle: service.overview.brewVersion == "—"
                ? "未检测到 / 加载中"
                : "Homebrew \(service.overview.brewVersion)",
            trailing: {
                Button {
                    service.refreshAll()
                } label: {
                    Text("刷新")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accentStart)
                .disabled(service.isBusy)
            }
        )
    }

    // MARK: - 概览

    private var overviewCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    OverviewItem(
                        label: "可更新",
                        value: "\(service.overview.outdatedCount)",
                        accent: service.overview.outdatedCount > 0 ? .orange : .secondary
                    )
                    Divider().frame(height: 36)
                    OverviewItem(
                        label: "可清理",
                        value: formatBytesShort(Double(service.overview.cleanableBytes)),
                        accent: service.overview.cleanableBytes > 0 ? Theme.accentStart : .secondary
                    )
                    Divider().frame(height: 36)
                    OverviewItem(
                        label: "公式",
                        value: "\(service.formulas.count)",
                        accent: .secondary
                    )
                    Divider().frame(height: 36)
                    OverviewItem(
                        label: "应用",
                        value: "\(service.casks.count)",
                        accent: .secondary
                    )
                }
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(service.overview.homebrewPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private struct OverviewItem: View {
        let label: String
        let value: String
        let accent: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
        }
    }

    // MARK: - 操作按钮

    private var actionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                // 安装输入框
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accentStart)
                    TextField("安装包，如 wget / google-chrome", text: $installText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { install() }
                    Button {
                        install()
                    } label: {
                        Text("安装")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.accentStart)
                    .disabled(installText.trimmingCharacters(in: .whitespaces).isEmpty || service.isBusy)
                }
                .padding(.horizontal, 2)

                Divider()

                // 动作按钮行
                HStack(spacing: 10) {
                    Button {
                        service.runUpdate()
                    } label: {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button {
                        service.runUpgradeAll()
                    } label: {
                        Label("升级全部", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStart)
                    .disabled(service.overview.outdatedCount == 0)

                    Button {
                        service.runCleanup()
                    } label: {
                        Label("清理", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(service.overview.cleanableBytes == 0)

                    Button {
                        service.runAutoremove()
                    } label: {
                        Label("清理依赖", systemImage: "link.badge.minus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    Button {
                        showOutput = true
                    } label: {
                        Label("输出", systemImage: "terminal")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(
            service.isBusy
                ? HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(service.runningTask)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(6)
                : nil,
            alignment: .topTrailing
        )
    }

    // MARK: - 可更新列表

    private var outdatedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                    Text("可更新（\(service.outdated.count)）")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                Divider()
                let items = showAllOutdated ? service.outdated : Array(service.outdated.prefix(outdatedLimit))
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                            HStack(spacing: 4) {
                                Text(item.current)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(item.latest)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.accentStart)
                            }
                        }
                        Spacer()
                        Button {
                            service.runUpgrade(name: item.name)
                        } label: {
                            Text("升级")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(service.isBusy)
                    }
                    if item.id != items.last?.id {
                        Divider()
                    }
                }
                if service.outdated.count > outdatedLimit {
                    Button {
                        showAllOutdated.toggle()
                    } label: {
                        Text(showAllOutdated ? "收起" : "还有 \(service.outdated.count - outdatedLimit) 个…")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accentStart)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - 已安装列表

    private var installedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("", selection: $listSegment) {
                        ForEach(ListSegment.allCases) { seg in
                            Text(seg.rawValue).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)

                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))

                    Spacer()
                }
                Divider()

                if displayList.isEmpty {
                    EmptyState(
                        icon: "tray",
                        title: "无匹配项",
                        subtitle: searchText.isEmpty ? "未安装任何\(listSegment == .cask ? "应用" : "命令行工具")" : "没有匹配「\(searchText)」的包"
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                } else {
                    ForEach(Array(displayList.enumerated()), id: \.element.id) { _, pkg in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(pkg.name)
                                        .font(.system(size: 13, weight: .medium))
                                    if !pkg.isLeaf {
                                        Image(systemName: "link")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if !pkg.version.isEmpty {
                                    Text(pkg.version)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                requestUninstall(pkg)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(pkg.isLeaf ? Color.secondary : Color.orange)
                            .help(pkg.isLeaf ? "卸载 \(pkg.name)" : "\(pkg.name) 被其他包依赖，卸载可能影响它们")
                        }
                        if pkg.id != displayList.last?.id {
                            Divider()
                        }
                    }
                    if searchText.isEmpty && fullListCount > installedLimit {
                        Button {
                            showAllInstalled.toggle()
                        } label: {
                            Text(showAllInstalled ? "收起" : "还有 \(fullListCount - installedLimit) 个…")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accentStart)
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var displayList: [BrewService.PkgInfo] {
        let source = listSegment == .cask ? service.casks : service.formulas
        let filtered = searchText.isEmpty
            ? source
            : source.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        if searchText.isEmpty && !showAllInstalled {
            return Array(filtered.prefix(installedLimit))
        }
        return filtered
    }

    private var fullListCount: Int {
        let source = listSegment == .cask ? service.casks : service.formulas
        return searchText.isEmpty
            ? source.count
            : source.filter { $0.name.localizedCaseInsensitiveContains(searchText) }.count
    }

    // MARK: - 交互动作

    private func install() {
        let name = installText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        service.runInstall(name: name)
        installText = ""
    }

    private func requestUninstall(_ pkg: BrewService.PkgInfo) {
        uninstallDependentCount = 0
        pendingUninstall = pkg
        service.dependentCount(name: pkg.name) { count in
            // 回调经由 DispatchQueue.main.async 派发到主线程
            Task { @MainActor in
                // 仅当用户还没取消时才更新
                if self.pendingUninstall?.id == pkg.id {
                    self.uninstallDependentCount = count
                }
            }
        }
    }

    // MARK: - 输出 Sheet

    private var outputSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("命令输出")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") { showOutput = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ScrollView {
                Text(service.lastOutput.isEmpty ? "（暂无输出）" : service.lastOutput)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(service.lastError ? Color.red : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)

            Spacer()
        }
        .frame(width: 560, height: 420)
    }
}
