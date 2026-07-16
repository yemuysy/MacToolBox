import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 截图预览面板：截图后展示大图，并提供「保存到… / 复制到剪贴板 / 在访达中显示 / 关闭」。
/// 让用户在截图后才决定如何保存，而不是被静默丢进某个目录。
struct ScreenshotPreviewView: View {
    let shot: ScreenshotEngine.CapturedShot
    let defaultDirectory: URL
    /// 用户点击「保存到…」并成功落盘后回调（参数为最终文件 URL）
    var onSaved: (URL) -> Void
    /// 关闭面板（无论是否保存）
    var onClose: () -> Void

    @State private var savedURL: URL?
    @State private var status: String = "预览：可「保存到…」选路径，或「复制到剪贴板」"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: shot.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 760, maxHeight: 520)
                    .padding(12)
            }
            .frame(minHeight: 200)

            Divider()

            HStack(spacing: 10) {
                Button { saveAs() } label: {
                    Label("保存到…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button { copyToClipboard() } label: {
                    Label("复制到剪贴板", systemImage: "doc.on.clipboard")
                }
                .controlSize(.large)

                if let url = savedURL {
                    Button { revealInFinder(url) } label: {
                        Label("在访达中显示", systemImage: "folder")
                    }
                    .controlSize(.large)
                }

                Spacer()

                Button { onClose() } label: { Text("关闭") }
                    .controlSize(.large)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(width: 780)
    }

    // MARK: - 动作

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ScreenshotEngine.buildFilename()
        panel.directoryURL = defaultDirectory
        panel.title = "保存截图"
        panel.message = "选择截图保存位置"
        if panel.runModal() == .OK, let url = panel.url {
            if ScreenshotEngine.save(shot, to: url) {
                savedURL = url
                status = "已保存到 \(url.lastPathComponent)"
                onSaved(url)
            } else {
                status = "保存失败：无法写入 \(url.path)"
            }
        }
    }

    private func copyToClipboard() {
        ScreenshotEngine.writeToClipboard(shot)
        status = "已复制到剪贴板"
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// 持有预览窗口的控制器（强引用，避免窗口被提前释放）。
/// 使用独立 NSPanel 浮起展示，关闭时清理临时文件。
@MainActor
final class ScreenshotPreviewController {
    static let shared = ScreenshotPreviewController()

    private var panel: NSPanel?
    private var currentShot: ScreenshotEngine.CapturedShot?

    func show(shot: ScreenshotEngine.CapturedShot,
              defaultDirectory: URL,
              onSaved: @escaping (URL) -> Void) {
        // 关闭上一个未处理的预览
        close()

        let view = ScreenshotPreviewView(
            shot: shot,
            defaultDirectory: defaultDirectory,
            onSaved: onSaved,
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "截图预览"
        panel.contentViewController = hosting
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()

        self.panel = panel
        self.currentShot = shot

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        if let shot = currentShot {
            ScreenshotEngine.cleanup(shot)
        }
        panel?.orderOut(nil)
        panel = nil
        currentShot = nil
    }
}
