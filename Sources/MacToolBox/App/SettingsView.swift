import SwiftUI
import AppKit

/// 偏好设置窗口内容：功能开关 + 全局快捷键 + 菜单栏显示 + 通用。
/// 由 AppDelegate 的独立 NSWindow 承载，从菜单栏右键「偏好设置」打开。
struct SettingsView: View {
    @State private var config: ConfigStore.MenuBarConfig = ConfigStore.shared.menuBarConfig()
    @StateObject private var service = SystemInfoService.shared
    @StateObject private var features = FeatureManager.shared
    @StateObject private var recorder = HotkeyRecorder()

    private var snap: SystemInfoService.SystemSnapshot { service.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("偏好设置")
                    .font(.system(size: 18, weight: .bold))
                    .padding(.bottom, 4)

                // 功能开关（核心架构能力）
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "功能开关", icon: "switch.2")
                        Text("关闭不需要的功能可减小主窗口、降低内存占用；关闭后该功能入口从主界面移除。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Divider().padding(.leading, 4)
                        ForEach(features.definitions) { def in
                            HStack(spacing: 8) {
                                Image(systemName: def.icon)
                                    .font(.system(size: 13))
                                    .frame(width: 18)
                                    .foregroundStyle(.secondary)
                                Text(def.title)
                                    .font(.system(size: 13))
                                Spacer()
                                if def.isCore {
                                    Text("常驻")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Toggle("", isOn: Binding(
                                        get: { features.isEnabled(def.id) },
                                        set: { features.setEnabled(def.id, $0) }
                                    ))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                }
                            }
                        }
                    }
                }

                // 全局快捷键
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "全局快捷键", icon: "command")
                        Text("点击右侧按钮后按下组合键录制；Esc 取消。需包含 ⌘ / ⌥ / ⌃ / ⇧ 之一。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Divider().padding(.leading, 4)
                        ForEach(HotkeyAction.allCases) { action in
                            HStack(spacing: 8) {
                                Text(action.title)
                                    .font(.system(size: 13))
                                Spacer()
                                Button {
                                    if recorder.recordingAction == action {
                                        recorder.cancel()
                                    } else {
                                        recorder.begin(action)
                                    }
                                } label: {
                                    if recorder.recordingAction == action {
                                        Text("取消").foregroundStyle(.red)
                                    } else {
                                        let hk = HotkeyService.shared.effectiveBinding(for: action)
                                        Text(hk.isNone ? "未设置" : hk.displayString)
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("恢复默认快捷键") { HotkeyService.shared.resetAll() }
                                .controlSize(.small)
                        }
                    }
                }

                // 菜单栏显示
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "菜单栏显示", icon: "menubar.rectangle")

                        Toggle("在菜单栏显示实时数据", isOn: Binding(
                            get: { config.showStats },
                            set: { config.showStats = $0; persist() }
                        ))
                        .toggleStyle(.switch)

                        if config.showStats {
                            Divider().padding(.leading, 4)
                            toggleRow("CPU 使用率", key: \.showCPU, icon: "cpu")
                            toggleRow("内存占用", key: \.showMemory, icon: "memorychip")
                            toggleRow("网速（下行 / 上行）", key: \.showNetwork, icon: "arrow.up.arrow.down")
                            toggleRow("温度", key: \.showTemperature, icon: "thermometer")
                        }
                    }
                }

                // 实时预览
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "预览", icon: "eye")
                        HStack(spacing: 10) {
                            if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
                               let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                            }
                            Text(previewText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                        )
                        Text(config.showStats
                             ? "未勾选的项不会出现在菜单栏；关闭总开关则只显示图标。"
                             : "总开关已关闭，菜单栏仅显示图标。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                // 通用
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "通用", icon: "gearshape")
                        HStack {
                            Text("关于")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("MacToolBox v2.0 · Apple Silicon 优化")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }

                Spacer()
            }
            .padding(18)
        }
        .frame(minWidth: 440, idealWidth: 460, minHeight: 520)
        .onDisappear { recorder.cancel() }
    }

    private func persist() {
        ConfigStore.shared.setMenuBarConfig(config)
    }

    private func toggleRow(_ title: String, key: WritableKeyPath<ConfigStore.MenuBarConfig, Bool>, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Toggle(title, isOn: Binding(
                get: { config[keyPath: key] },
                set: { config[keyPath: key] = $0; persist() }
            ))
            .toggleStyle(.switch)
        }
    }

    private var previewText: String {
        guard config.showStats else { return "" }
        var parts: [String] = []
        if config.showCPU { parts.append("C\(String(format: "%.0f", snap.cpuUsage))") }
        if config.showMemory { parts.append("M\(String(format: "%.0f", snap.memoryUsage))") }
        if config.showNetwork {
            parts.append("↓\(formatRateShort(snap.networkDown))")
            parts.append("↑\(formatRateShort(snap.networkUp))")
        }
        if config.showTemperature {
            parts.append(snap.temperature.map { String(format: "%.0f°", $0) } ?? "—")
        }
        return parts.isEmpty ? "(无)" : parts.joined(separator: " ")
    }
}

/// 快捷键录制器：在设置窗口打开期间监听本地按键事件，捕获后写入 HotkeyService。
@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published var recordingAction: HotkeyAction?
    private var monitor: Any?

    func begin(_ action: HotkeyAction) {
        recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let act = self?.recordingAction else { return }
                self?.handle(event, action: act)
            }
            return nil
        }
    }

    func cancel() {
        end()
        recordingAction = nil
    }

    private func handle(_ event: NSEvent, action: HotkeyAction) {
        end()
        recordingAction = nil
        if event.keyCode == 53 { return } // Esc 取消
        let hk = Hotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: Hotkey.from(cocoa: event.modifierFlags)
        )
        HotkeyService.shared.setBinding(hk, for: action)
    }

    private func end() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
