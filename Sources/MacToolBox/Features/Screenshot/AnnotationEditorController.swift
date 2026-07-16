import AppKit

/// 截图标注编辑器窗口：工具栏（工具/颜色/线宽/撤销重做/复制/保存/贴图/OCR/取色/长截图）+ 画布。
final class AnnotationEditorController: NSWindowController {
    private let canvas = AnnotationCanvas()
    private let scroll = NSScrollView()
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let colorWell = NSColorWell()
    private let widthSegments = NSSegmentedControl()
    private let statusLabel = NSTextField(labelWithString: "")

    /// 强引用集合：窗口在屏幕上期间保留控制器，避免按钮 target 变野指针导致无法操作
    /// （否则 `edit` 返回的局部控制器被 ARC 释放，窗口虽显示但「复制/保存/贴图」全部失效）。
    private static var retainedEditors: [AnnotationEditorController] = []

    static func edit(_ image: NSImage) {
        let c = AnnotationEditorController()
        retainedEditors.append(c)
        c.show(image: image)
    }

    convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "截图标注"
        win.minSize = NSSize(width: 640, height: 480)
        self.init(window: win)
    }

    private func show(image: NSImage) {
        guard let win = window else { return }
        setupToolbar()
        setupCanvas()

        let content = NSView(frame: win.contentLayoutRect)
        content.wantsLayer = true

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbarHost)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbarHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbarHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbarHost.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.topAnchor.constraint(equalTo: toolbarHost.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        win.contentView = content
        canvas.baseImage = image
        canvas.frame = NSRect(origin: .zero, size: NSSize(width: max(image.size.width, 800), height: max(image.size.height, 600)))
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                Self.retainedEditors.removeAll { $0 === self }
            }
        }
        refreshToolbarState()
    }

    // MARK: 工具栏

    private lazy var toolbarHost: NSView = {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true; v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        v.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return v
    }()

    private func setupToolbar() {
        let host = toolbarHost
        host.subviews.forEach { $0.removeFromSuperview() }

        let tools: [AnnotationTool] = [.select, .arrow, .rect, .ellipse, .text, .numbered, .mosaic, .pen, .colorPick]
        let left = NSStackView(); left.spacing = 4
        for t in tools {
            let b = NSButton(image: NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)!,
                             target: self, action: #selector(selectTool(_:)))
            b.setButtonType(.toggle); b.bezelStyle = .texturedRounded
            b.toolTip = t.title; b.tag = tools.firstIndex(of: t) ?? 0
            toolButtons[t] = b; left.addArrangedSubview(b)
        }

        undoButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "撤销")
        undoButton.bezelStyle = .texturedRounded; undoButton.target = self; undoButton.action = #selector(undo)
        redoButton.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "重做")
        redoButton.bezelStyle = .texturedRounded; redoButton.target = self; redoButton.action = #selector(redo)

        colorWell.target = self; colorWell.action = #selector(colorChanged(_:))

        widthSegments.segmentCount = 3
        widthSegments.setLabel("细", forSegment: 0); widthSegments.setWidth(36, forSegment: 0)
        widthSegments.setLabel("中", forSegment: 1); widthSegments.setWidth(36, forSegment: 1)
        widthSegments.setLabel("粗", forSegment: 2); widthSegments.setWidth(36, forSegment: 2)
        widthSegments.selectedSegment = 1
        widthSegments.target = self; widthSegments.action = #selector(widthChanged(_:))

        let copy = NSButton(title: "复制", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!, target: self, action: #selector(copyImage(_:)))
        copy.bezelStyle = .texturedRounded
        let save = NSButton(title: "保存", image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)!, target: self, action: #selector(saveImage(_:)))
        save.bezelStyle = .texturedRounded
        let pin = NSButton(title: "贴图", image: NSImage(systemSymbolName: "pin", accessibilityDescription: nil)!, target: self, action: #selector(pinImage(_:)))
        pin.bezelStyle = .texturedRounded
        let ocr = NSButton(title: "OCR", image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)!, target: self, action: #selector(runOCR(_:)))
        ocr.bezelStyle = .texturedRounded
        let long = NSButton(title: "长截图", image: NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)!, target: self, action: #selector(longScreenshot(_:)))
        long.bezelStyle = .texturedRounded

        let leftWrap = wrap(left, pad: 8)
        let mid = wrap(NSStackView(views: [undoButton, redoButton, colorWell, widthSegments]), pad: 8)
        let right = wrap(NSStackView(views: [copy, save, pin, ocr, long]), pad: 8)

        [leftWrap, mid, right].forEach { host.addSubview($0) }
        NSLayoutConstraint.activate([
            leftWrap.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            leftWrap.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            mid.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            mid.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ])
    }

    private func wrap(_ v: NSView, pad: CGFloat) -> NSView {
        let box = NSView(); box.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            v.topAnchor.constraint(equalTo: box.topAnchor),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        return box
    }

    private func setupCanvas() {
        canvas.wantsLayer = true
        canvas.onAnnotationsChanged = { [weak self] in self?.refreshToolbarState() }
    }

    private func refreshToolbarState() {
        for (t, b) in toolButtons { b.state = (t == canvas.tool) ? .on : .off }
        undoButton.isEnabled = true
        redoButton.isEnabled = true
        colorWell.color = canvas.currentColor
    }

    // MARK: 动作

    @objc private func selectTool(_ sender: NSButton) {
        let idx = sender.tag
        guard AnnotationTool.allCases.indices.contains(idx) else { return }
        let t = AnnotationTool.allCases[idx]
        canvas.tool = t
        if t == .colorPick { colorPickMode(sender) }
        refreshToolbarState()
    }

    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.applyColor(sender.color)
    }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        let w: CGFloat = [2, 4, 8][sender.selectedSegment]
        canvas.applyLineWidth(w)
    }

    @objc private func copyImage(_ sender: Any) {
        let img = canvas.compose()
        let pb = NSPasteboard.general
        pb.clearContents()
        if let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        pb.writeObjects([img])
        flash("已复制到剪贴板")
    }

    @objc private func saveImage(_ sender: Any) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "MacToolBox-\(Self.timestamp()).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let img = canvas.compose()
        guard ScreenshotFlow.savePNG(img, to: url) else { flash("保存失败"); return }
        flash("已保存到 \(url.lastPathComponent)")
    }

    @objc private func pinImage(_ sender: Any) {
        PinManager.shared.pin(canvas.compose())
        flash("已贴图")
    }

    @objc private func runOCR(_ sender: Any) {
        let img = canvas.compose()
        flash("OCR 识别中…")
        OCRService.recognize(image: img) { text in
            DispatchQueue.main.async { [weak self] in
                self?.showOCRResult(text)
            }
        }
    }

    @objc private func longScreenshot(_ sender: Any) {
        guard let img = CaptureSession.captureFrontmostWindowFull() else {
            flash("未找到可捕获的窗口"); return
        }
        Self.edit(img)
    }

    private func showOCRResult(_ text: String) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "OCR 文字"
        let tv = NSTextView(frame: NSRect(x: 10, y: 40, width: 400, height: 250))
        tv.isEditable = true; tv.font = NSFont.systemFont(ofSize: 13)
        tv.string = text.isEmpty ? "（未识别到文字）" : text
        let copy = NSButton(title: "复制全部", target: self, action: #selector(copyOCR(_:)))
        copy.frame = NSRect(x: 300, y: 8, width: 100, height: 28)
        copy.keyEquivalent = ""
        let ctx = OCRContext(text: text)
        ocrCopyTargets[copy] = ctx
        win.contentView = NSView(); win.contentView?.addSubview(tv); win.contentView?.addSubview(copy)
        win.center(); win.makeKeyAndOrderFront(nil)
    }

    private var ocrCopyTargets: [NSButton: OCRContext] = [:]
    private struct OCRContext { let text: String }
    @objc private func copyOCR(_ sender: NSButton) {
        guard let ctx = ocrCopyTargets[sender] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ctx.text, forType: .string)
    }

    @objc private func colorPickMode(_ sender: Any) {
        let sampler = NSColorSampler()
        sampler.show { [weak self] color in
            guard let self, let color else { return }
            // NSColorSampler 回调在主线程；断言主线程以合规调用 @MainActor 的画布。
            MainActor.assumeIsolated {
                self.canvas.applyColor(color)
                self.canvas.currentColor = color
            }
        }
    }

    private func flash(_ msg: String) {
        statusLabel.stringValue = msg
    }

    private static func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: window?.close()       // Esc
        case 6:  canvas.undo()          // Z
        case 7:  canvas.redo()          // X
        default: super.keyDown(with: event)
        }
    }
}
