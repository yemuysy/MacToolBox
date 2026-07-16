import SwiftUI
import AppKit
import Combine

/// 截图功能界面：模式（全屏/区域/窗口）+ 保存位置（文件/剪贴板）+ 快捷键展示 + 贴图 + 最近截图。
struct ScreenshotView: View {
    @State private var mode: CaptureMode = .region
    @State private var saveToClipboard = false
    @State private var saveDir: URL
    @State private var recent: [SavedShot] = []
    @State private var status: String = "选择模式后开始截图"
    @State private var isBusy = false
    @State private var hasPermission = ScreenshotEngine.checkScreenRecordingPermission()
    /// 最近一次捕获保存的文件（用于「贴图」按钮）
    @State private var lastCapturedURL: URL?

    init() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        _saveDir = State(initialValue: desktop)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TabHeaderCard(
                    icon: "camera.viewfinder",
                    title: "截图",
                    subtitle: "区域 / 全屏 / 窗口 · 保存文件或剪贴板 · 支持贴图"
                )

                // 权限引导（无屏幕录制权限时显示）
                if !hasPermission {
                    permissionGuideCard
                }

                // 快捷键展示（独立子视图，快捷键变更时只重渲染该卡而非整页）
                HotkeySection()

                // 模式
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "截图模式", icon: "rectangle.on.rectangle")
                        Picker("", selection: $mode) {
                            ForEach(CaptureMode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                // 保存
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "保存位置", icon: "tray.and.arrow.down")
                        Toggle("复制到剪贴板（不保存文件）", isOn: $saveToClipboard)
                            .toggleStyle(.switch)
                        if !saveToClipboard {
                            Divider().padding(.leading, 4)
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(saveDir.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("更改…") { chooseDir() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                // 开始
                HStack(spacing: 10) {
                    Button {
                        takeScreenshot()
                    } label: {
                        Label(mode == .region ? "框选区域" : (mode == .window ? "捕获窗口" : "截取全屏"),
                              systemImage: "camera")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy)

                    if let url = lastCapturedURL {
                        Button {
                            PinnedImageManager.shared.pin(url: url)
                        } label: {
                            Label("贴图", systemImage: "pin.fill")
                                .frame(minWidth: 80)
                        }
                        .controlSize(.large)
                    }

                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                // 状态
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                // 最近截图
                if !recent.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "最近截图", icon: "photo.on.rectangle.angled")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 10) {
                                ForEach(recent) { shot in
                                    recentItem(shot)
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            hasPermission = ScreenshotEngine.checkScreenRecordingPermission()
        }
    }

    /// 快捷键展示子视图：把 `.hotkeyBindingsChanged` 监听收敛到本卡内部，
    /// 快捷键变更时只重渲染这张卡，不会触发整个 ScreenshotView 重渲染。
    private struct HotkeySection: View {
        @State private var tick = 0

        var body: some View {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "快捷键", icon: "command")
                    let shotActions: [HotkeyAction] = [.regionScreenshot, .fullScreenshot, .windowScreenshot, .pinScreenshot]
                    let bindings = HotkeyService.shared.currentBindings()
                    ForEach(shotActions) { action in
                        HStack(spacing: 8) {
                            Text(action.title)
                                .font(.system(size: 13))
                            Spacer()
                            let hk = bindings[action] ?? action.default
                            Text(hk.isNone ? "未设置" : hk.displayString)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: .windowBackgroundColor))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                                )
                        }
                    }
                    Text("触发对应快捷键即可截图/贴图；可在「偏好设置 → 全局快捷键」中修改。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hotkeyBindingsChanged)) { _ in
                tick += 1
            }
        }
    }

    private func recentItem(_ shot: SavedShot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let img = shot.image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 90)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            } else {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor)).frame(height: 90).cornerRadius(6)
            }
            Text(shot.url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([shot.url])
            }
            Button("贴图") {
                PinnedImageManager.shared.pin(url: shot.url)
            }
        }
    }

    // MARK: - 权限引导

    /// 屏幕录制权限引导卡片：检测到无权限时显示，引导用户前往系统设置授权。
    private var permissionGuideCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "屏幕录制权限", icon: "shield.slash")
                Text("截图需要屏幕录制权限。请在系统设置中授予 MacToolBox 权限，然后点击下方按钮刷新。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                    }
                    .controlSize(.small)
                    Button {
                        hasPermission = ScreenshotEngine.checkScreenRecordingPermission()
                        if hasPermission {
                            status = "权限已就绪"
                        }
                    } label: {
                        Label("刷新权限状态", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 行为

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveDir
        if panel.runModal() == .OK, let url = panel.url {
            saveDir = url
        }
    }

    private func takeScreenshot() {
        isBusy = true
        status = "准备截图…"
        if mode == .region {
            RegionSelector.begin { rect in
                Task { @MainActor in
                    if let rect {
                        performCapture(region: rect)
                    } else {
                        isBusy = false
                        status = "已取消"
                    }
                }
            }
        } else {
            performCapture(region: nil)
        }
    }

    @MainActor
    private func performCapture(region: CGRect?) {
        let result = ScreenshotEngine.capture(
            mode,
            region: region,
            saveToClipboard: saveToClipboard,
            directory: saveDir
        )
        isBusy = false
        switch result {
        case .success(let url):
            if let url {
                recent.insert(SavedShot(url: url, mode: mode, date: Date()), at: 0)
                recent = Array(recent.prefix(12))
                lastCapturedURL = url
                status = "已保存到 \(url.lastPathComponent)"
            } else {
                status = "已复制到剪贴板"
            }
        case .failure(let err):
            if let shotErr = err as? ScreenshotEngine.ScreenshotError,
               case .noPermission = shotErr {
                hasPermission = false
            }
            status = err.localizedDescription
        }
    }
}

/// 一条最近截图记录
struct SavedShot: Identifiable {
    let id = UUID()
    let url: URL
    let mode: CaptureMode
    let date: Date
    /// 缩略图：在创建时解码一次并缓存，避免每次界面重渲染都从磁盘重新解码（最多 12 张）。
    let image: NSImage?

    init(url: URL, mode: CaptureMode, date: Date, image: NSImage? = nil) {
        self.url = url
        self.mode = mode
        self.date = date
        self.image = image ?? NSImage(contentsOf: url)
    }
}
