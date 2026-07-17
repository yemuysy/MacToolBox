import SwiftUI

/// 右键增强设置页：主开关 + 启用引导 + 新建文件 / 模板 / 复制 / 打开 / 常用目录 / 动作开关。
/// 架构对标开源右键增强（RightKit / SaneClick / Flicker）：Finder Sync 扩展注入一级菜单，
/// 配置经 App Group 共享文件下发；同时提供 NSServices「服务」子菜单免费路线（免签名）。
struct RightClickView: View {
    @StateObject private var service = RightClickService.shared

    private var config: RightClickConfig { service.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                guideCard
                newFileCard
                templateCard
                openCard
                commonDirsCard
                actionsCard
                tipCard
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .onAppear { service.publishMenuConfig() }
    }

    // MARK: - 头部

    private var header: some View {
        TabHeaderCard(
            icon: "rectangle.on.folder",
            title: "右键增强",
            subtitle: "Finder 右键：新建/模板/复制/打开/显示/删除/隐藏/常用目录"
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
        return service.extensionAlive ? "已接入" : "待开启文件提供程序"
    }

    private var statusColor: Color {
        if !config.enabled { return .secondary }
        return service.extensionAlive ? .green : .orange
    }

    // MARK: - 启用引导

    private var guideCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "启用 Finder 扩展（一级菜单）", icon: "puzzlepiece.extension")
                Text("Finder Sync 扩展已被系统识别并安装，但 macOS 14+ 把它归类在「登录项 → 文件提供程序」里，且默认关闭。开启步骤：\n1. 打开「系统设置 → 通用 → 登录项」；\n2. 找到「MacToolBox 扩展」，打开「文件提供程序」开关；\n3. 回到本页,扩展状态会变绿。\n\n如果完全看不到「MacToolBox 扩展」,说明 FinderSyncExt 没被 pkd 加载,试着重启电脑或执行: `pluginkit -e use -i com.yemu.mactoolbox.FinderSyncExt`。\n\n**免签名的服务子菜单路线**仍可用: Finder 右键任意文件 → 服务 → 「MacToolBox：xxx」。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        openLoginItemsSettings()
                    } label: {
                        Label("打开登录项设置", systemImage: "gearshape")
                    }
                    .controlSize(.small)
                    Button {
                        registerExtensionManually()
                    } label: {
                        Label("手动注册扩展", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("运行 pluginkit -e use -i <bundleID> 让 pkd 立刻加载扩展")
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

    /// 打开 macOS 14+ 的「登录项」设置页(扩展被归类到「文件提供程序」)
    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 让 pkd 立刻加载扩展（无需重启）
    private func registerExtensionManually() {
        let task = Process()
        task.launchPath = "/usr/bin/pluginkit"
        task.arguments = ["-e", "use", "-i", "com.yemu.mactoolbox.FinderSyncExt"]
        do {
            try task.run()
            task.waitUntilExit()
            rcLog("RightClick: manual pluginkit registration triggered (exit=\(task.terminationStatus))")
        } catch {
            rcLog("RightClick: pluginkit failed: \(error.localizedDescription)")
        }
        // 触发配置重新下发,扩展接上后会自动请求
        service.publishMenuConfig()
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

    // MARK: - 从模板新建

    private var templateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "从模板新建", icon: "doc.on.doc.fill")
                toggleRow("启从模板新建", icon: "doc.on.doc.fill",
                          desc: "把模板目录里的文件一键复制到当前目录（RightKit 标志性功能）",
                          isOn: Binding(
                            get: { config.showNewFileFromTemplate },
                            set: { v in service.update { $0.showNewFileFromTemplate = v } }))
                Divider().padding(.leading, 4)
                HStack(spacing: 8) {
                    Button {
                        if config.templateFolder == nil { service.scanDefaultTerminal() }
                        pickTemplateFolder()
                    } label: { Label("选择模板目录…", systemImage: "folder.badge.plus") }
                        .controlSize(.small)
                    Spacer()
                }
                if let folder = config.templateFolder {
                    Text(folder)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if config.templateFiles.isEmpty {
                        Text("该目录暂无可见文件。").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("模板（\(config.templateFiles.count)）：")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(config.templateFiles, id: \.self) { name in
                                    Text(name)
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Theme.cardBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                } else {
                    Text("尚未选择模板目录。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 用 App 打开 / 终端

    private var openCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "打开方式", icon: "app.dock")
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

                Divider().padding(.leading, 4)

                Toggle("显示「在终端打开」", isOn: Binding(
                    get: { config.showOpenInTerminal },
                    set: { v in service.update { $0.showOpenInTerminal = v } }
                ))
                .toggleStyle(.switch)
                HStack(spacing: 8) {
                    Text("终端程序：\(service.terminalName())")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        pickTerminal()
                    } label: { Label("更改…", systemImage: "pencil") }
                        .controlSize(.small)
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
                toggleRow("复制文件名", icon: "character.textbox",
                          desc: "把选中项文件名（不含路径）写入剪贴板",
                          isOn: Binding(
                            get: { config.showCopyName },
                            set: { v in service.update { $0.showCopyName = v } }))
                Divider().padding(.leading, 4)
                toggleRow("在 Finder 中显示", icon: "eye.fill",
                          desc: "在 Finder 中定位并选中选中项",
                          isOn: Binding(
                            get: { config.showRevealInFinder },
                            set: { v in service.update { $0.showRevealInFinder = v } }))
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
                Text("• Finder Sync 扩展会被系统识别,但 macOS 14+ 把它放在「系统设置 → 通用 → 登录项 → 文件提供程序」,默认关闭,需手动开启一次。\n• 走 NSServices「服务」子菜单也能用(无需开启),Finder 右键 → 服务 → 「MacToolBox：xxx」。\n• 扩展仅渲染菜单并转发点击,所有文件操作在主程序执行。\n• 直接删除为危险操作,已加系统路径守卫与确认弹窗。")
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

    private func pickTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.application]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        if panel.runModal() == .OK, let url = panel.url {
            service.setTerminal(url)
        }
    }

    private func pickTemplateFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            service.setTemplateFolder(url)
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
