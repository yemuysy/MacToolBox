import SwiftUI
import AppKit

/// hosts 语法高亮编辑器（参考 SwitchHosts 的编辑器体验）。
///
/// 底层用 NSTextView，逐行着色：
/// - 注释行（`#` 开头）→ 绿色
/// - 其余文本 → 默认色 + 等宽字体
///
/// 关键：只在 `textStorage` 上「叠加属性」而非替换字符串，并加 `isRecoloring` 守卫，
/// 避免输入时光标跳动 / 无限递归。
struct HostsTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var onSubmit: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.backgroundColor = .clear
        textView.setAccessibilityIdentifier("hostsEditor")

        context.coordinator.textView = textView
        context.coordinator.applyHighlighting() // 初始着色
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // 外部文本变化（如切换方案）时同步，但避免与用户输入冲突
        if textView.string != text {
            context.coordinator.isUpdatingExternally = true
            textView.string = text
            context.coordinator.isUpdatingExternally = false
            context.coordinator.applyHighlighting()
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HostsTextView
        weak var textView: NSTextView?
        var isRecoloring = false
        var isUpdatingExternally = false

        init(_ parent: HostsTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            if isUpdatingExternally { return }
            // 同步文本到 SwiftUI
            parent.text = textView.string
            // 重新着色（仅叠加属性，不替换字符串，光标不跳）
            applyHighlighting()
        }

        /// 仅叠加着色属性，绝不替换字符串内容
        func applyHighlighting() {
            guard !isRecoloring, let storage = textView?.textStorage else { return }
            isRecoloring = true
            defer { isRecoloring = false }

            let fullText = storage.string as NSString
            let fullRange = NSRange(location: 0, length: fullText.length)
            let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let baseColor = NSColor.textColor

            storage.addAttribute(.font, value: baseFont, range: fullRange)
            storage.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

            // 注释行（# 开头）染绿
            fullText.enumerateSubstrings(in: fullRange, options: .byLines) { _, lineRange, _, _ in
                let line = fullText.substring(with: lineRange)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                    storage.addAttribute(.foregroundColor,
                                         value: NSColor.systemGreen.withAlphaComponent(0.85),
                                         range: lineRange)
                }
            }
        }
    }
}
