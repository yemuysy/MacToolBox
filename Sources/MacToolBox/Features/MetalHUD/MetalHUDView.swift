import SwiftUI

/// Metal HUD 开关视图
struct MetalHUDView: View {
    @ObservedObject private var service = MetalHUDService.shared

    @State private var selectedAppPath: String = ""
    @State private var launchMessage: String = ""
    @State private var launchOK: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerCard
            controlCard
            appLaunchCard
            infoCard
            Spacer()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        TabHeaderCard(
            icon: "speedometer",
            title: "Metal HUD（全局）",
            subtitle: service.isEnabled
                ? "已开启 · 之后新启动的 Metal 应用会显示 HUD"
                : "已关闭",
            trailing: {
                Toggle("", isOn: Binding(
                    get: { service.isEnabled },
                    set: { _ in service.toggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.large)
            }
        )
    }

    private var controlCard: some View {
        Card {
            HStack(spacing: 10) {
                Button("立即开启") { service.enable() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentStart)
                    .disabled(service.isEnabled)
                    .controlSize(.regular)

                Button("立即关闭") { service.disable() }
                    .buttonStyle(.bordered)
                    .disabled(!service.isEnabled)
                    .controlSize(.regular)

                Spacer()
            }
        }
    }

    // MARK: - 为指定应用开启 HUD 并启动

    private var appLaunchCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "为指定应用开启 HUD 并启动", icon: "app.dock")

                Text("选一个 .app，本工具会直接拉起它的二进制并注入 METAL_HUD_ENABLED=1，HUD 必定出现（已运行实例会先关闭）。这是最可靠的方式。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        pickApp()
                    } label: {
                        Label("选择应用…", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    if !selectedAppPath.isEmpty {
                        Button("启动（带 HUD）") {
                            let r = service.launchAppWithHUD(selectedAppPath)
                            launchOK = r.success
                            launchMessage = r.message
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accentStart)
                        .controlSize(.regular)
                    }

                    Spacer()
                }

                if !selectedAppPath.isEmpty {
                    InfoRow(label: "应用", value: (selectedAppPath as NSString).lastPathComponent)
                }

                if !launchMessage.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: launchOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(launchOK ? Color.green : Color.orange)
                        Text(launchMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(launchOK ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 说明

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "说明", icon: "info.circle")

                VStack(alignment: .leading, spacing: 6) {
                    bullet("全局开关：通过 launchctl setenv 设置，仅对之后新启动且从系统环境继承的 App 有效")
                    bullet("已运行的应用需要先退出，再重新打开才能看到 HUD")
                    bullet("指定应用启动：直接以环境变量拉起二进制，效果最稳妥，推荐用这个")
                    bullet("HUD 会显示在该 App 窗口右上角（GPU 占用、帧率、绘制调用等）")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 选择 .app

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择要开启 Metal HUD 的应用程序"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            selectedAppPath = url.path
            launchMessage = ""
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Theme.accentStart)
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
