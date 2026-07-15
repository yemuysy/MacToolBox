import SwiftUI

/// 右键增强设置页：主开关 + 启用引导 + 新建类型 / 用 App 打开 / 常用目录 / 动作开关。
struct RightClickView: View {
    @StateObject private var service = RightClickService.shared

    private var config: RightClickConfig { service.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                guideCard
                newFileCard
                openWithCard
                commonDirsCard
                actionsCard
                tipCard
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .onAppear { service.pushMenuConfig() }
    }

    // MARK: - 头部

    private var header: some View {
        TabHeaderCard(
            icon: "rectangle.on.folder",
            title: "右键增强",
            subtitle: "Finder 右键菜单：新建文件 / 复制路径 / 用 App 打开 / 删除 / 隐藏 / 常用目录"
        ) {
            HStack(spacing: 10) {
                StatusPill(text: statusText, color: statusColor)
                Toggle("", isOn: Binding(
                    get: { config.enabled },
                    set: { service.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    private var statusText: String {
        if !config.enabled { return "已关闭" }
        return service.extensionAlive ? "已接入" : "待启用扩展"
    }

    private var statusColor: Color {
        if !config.enabled { return .secondary }
        return service.extensionAlive ? .green : .orange
    }

    // MARK: - 启用引导

    private var guideCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "启用 Finder 扩展", icon: "puzzlepiece.extension")
                Text("右键菜单由独立的 Finder Sync 扩展提供，需手动启用一次：\n1. 将 MacToolBox 放到 /Applications；\n2. 打开「系统设置 → 扩展 → Finder」，开启 MacToolBox；\n3. 在本页打开上方开关。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        openExtensionsSettings()
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                    }
                    .controlSize(.small)
                    Button {
                        revealInFinder()
                    } label: {
                        Label("在 Finder 中显示 App", systemImage: "folder")
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 新建文件

    private var newFileCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "新建文件", icon: "doc.badge.plus")
                toggleRow("启用新建文件", icon: "doc.badge.plus",
                          desc: "右键空白处 / 目录生成模板文件",
                          isOn: Binding(
                            get: { config.showNewFile },
                            set: { v in service.update { $0.showNewFile = v } }))
                Divider().padding(.leading, 4)
                Text("可选类型（逗号或空格分隔，自动去重）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("txt, md, json, csv", text: Binding(
                    get: { config.newFileTypes.joined(separator: ", ") },
                    set: { raw in service.update { $0.newFileTypes = parseTypes(raw) } }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - 用 App 打开

    private var openWithCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "用 App 打开", icon: "app.dock")
                Toggle("显示「用 App 打开」", isOn: Binding(
                    get: { config.showOpenWith },
                    set: { v in service.update { $0.showOpenWith = v } }
                ))
                .toggleStyle(.switch)
                HStack(spacing: 8) {
                    Button { service.scanDefaultApps() } label: { Label("扫描常用编辑器", systemImage: "magnifyingglass") }
                        .controlSize(.small)
                    Button { pickApp() } label: { Label("添加 App…", systemImage: "plus") }
                        .controlSize(.small)
                    Spacer()
                }
                if config.openWithApps.isEmpty {
                    Text("尚未添加任何 App。").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(config.openWithApps) { app in
                        HStack(spacing: 8) {
                            Image(systemName: "app.fill").foregroundStyle(.secondary)
                            Text(app.name).font(.system(size: 12))
                            Spacer()
                            Button {
                                service.removeApp(app.bundleID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 常用目录

    private var commonDirsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "常用目录", icon: "folder.fill")
                Toggle("显示「常用目录」", isOn: Binding(
                    get: { config.showCommonDirs },
                    set: { v in service.update { $0.showCommonDirs = v } }
                ))
                .toggleStyle(.switch)
                Button { pickDir() } label: { Label("添加目录…", systemImage: "plus") }
                    .controlSize(.small)
                if config.commonDirs.isEmpty {
                    Text("尚未添加任何目录。").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(config.commonDirs) { dir in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(dir.name).font(.system(size: 12))
                            Spacer()
                            Button {
                                service.removeCommonDir(dir.path)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 其它动作开关

    private var actionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "其它动作", icon: "ellipsis.curly")
                toggleRow("复制路径", icon: "doc.on.clipboard",
                          desc: "把选中项绝对路径写入剪贴板",
                          isOn: Binding(
                            get: { config.showCopyPath },
                            set: { v in service.update { $0.showCopyPath = v } }))
                Divider().padding(.leading, 4)
                toggleRow("直接删除", icon: "trash",
                          desc: "跳过废纸篓删除（带确认弹窗，系统路径受保护）",
                          isOn: Binding(
                            get: { config.showDelete },
                            set: { v in service.update { $0.showDelete = v } }))
                Divider().padding(.leading, 4)
                toggleRow("隐藏 / 显示", icon: "eye.slash",
                          desc: "切换选中项的隐藏标志（UF_HIDDEN）",
                          isOn: Binding(
                            get: { config.showToggleHidden },
                            set: { v in service.update { $0.showToggleHidden = v } }))
            }
        }
    }

    private var tipCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "说明", icon: "info.circle")
                Text("• 扩展需手动在「系统设置 → 扩展 → Finder」中开启一次；之后由主程序自动推送菜单配置。\n• 扩展仅渲染菜单并转发点击，所有文件操作在主程序执行。\n• 直接删除为危险操作，已加系统路径守卫与确认弹窗。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 复用行

    private func toggleRow(
        _ title: String,
        icon: String,
        desc: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(desc).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    // MARK: - 选择器 / 系统设置

    private func parseTypes(_ raw: String) -> [String] {
        let parts = raw.split(omittingEmptySubsequences: true) { $0 == "," || $0.isWhitespace }
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return Array(Set(cleaned))
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.application]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        if panel.runModal() == .OK {
            for url in panel.urls { service.addApp(url) }
        }
    }

    private func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { service.addCommonDir(url) }
        }
    }

    private func openExtensionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.extensions") {
            NSWorkspace.shared.open(url)
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
