import AppKit

// MARK: - 标注工具栏：紧凑毛玻璃药丸风格

final class AnnotationToolbar: NSView {

    // MARK: - 状态

    private(set) var selectedTool: AnnotationTool? = nil {
        didSet { updateToolButtons() }
    }

    private(set) var selectedColor: NSColor = NSColor(red: 1.0, green: 0.231, blue: 0.188, alpha: 1) {
        didSet { colorWell.layer?.backgroundColor = selectedColor.cgColor }
    }

    /// 工具切换回调。
    var onToolChanged: ((AnnotationTool) -> Void)?

    /// 取消工具选择回调（再次点击已选中工具时触发），让上层退出绘制模式。
    var onToolDeselected: (() -> Void)?
    /// 颜色切换回调。
    var onColorChanged: ((NSColor) -> Void)?

    // MARK: - 操作回调

    var onUndo: (() -> Void)?
    var onDone: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPin: (() -> Void)?
    var onCancel: (() -> Void)?

    func setUndoEnabled(_ enabled: Bool) {
        undoButton.alphaValue = enabled ? 1.0 : 0.3
        undoButton.isEnabled = enabled
    }

    // MARK: - UI 引用

    private var toolButtons: [NSButton] = []

    /// 颜色色块按钮（点击弹出系统取色器）。
    private lazy var colorWell: NSButton = {
        let btn = NSButton(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.title = ""
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 6
        btn.layer?.borderWidth = 1.5
        btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        btn.layer?.shadowColor = NSColor.black.withAlphaComponent(0.15).cgColor
        btn.layer?.shadowOffset = CGSize(width: 0, height: 1)
        btn.layer?.shadowRadius = 2
        btn.layer?.shadowOpacity = 1
        btn.layer?.backgroundColor = selectedColor.cgColor
        btn.target = self
        btn.action = #selector(pickColor)
        // NSButton 无 title/image 时 intrinsic size 为 0，NSStackView 会压缩 → 显式约束
        btn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return btn
    }()

    private lazy var undoButton = makeIconButton("arrow.uturn.backward")
    private lazy var copyButton = makeIconButton("doc.on.doc")
    private lazy var pinButton   = makeIconButton("pin.fill")
    private lazy var doneButton  = makeIconButton("checkmark.circle.fill")
    private lazy var cancelButton = makeIconButton("xmark.circle.fill")

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 构建 UI

    private func buildUI() {
        // 毛玻璃背景 + 圆角药丸
        layer?.cornerRadius = 12
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.shadowRadius = 8
        layer?.shadowOpacity = 1
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // --- 工具组 ---
        for tool in AnnotationTool.allCases {
            let btn = makeToolButton(tool)
            toolButtons.append(btn)
            stack.addArrangedSubview(btn)
        }

        // --- 分隔 ---
        stack.addArrangedSubview(separator())

        // --- 颜色选择器（单色块） ---
        stack.addArrangedSubview(colorWell)

        // --- 弹性空间（推动右侧操作按钮靠右） ---
        let spacer = NSView()
        // NSStackView 中无固有尺寸的视图默认压缩为 0；
        // 通过低优先级 contentHugging 让其他视图先拿空间后，spacer 占据剩余宽度。
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        // --- 操作组 ---
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(pinButton)
        stack.addArrangedSubview(doneButton)
        stack.addArrangedSubview(cancelButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateToolButtons()
        setUndoEnabled(false)
    }

    // MARK: - 按钮工厂

    private func makeToolButton(_ tool: AnnotationTool) -> NSButton {
        let btn = NSButton(
            image: NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil)!,
            target: self, action: #selector(toolTapped(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.toolTip = tool.rawValue
        btn.tag = AnnotationTool.allCases.firstIndex(of: tool)!
        return btn
    }

    private func makeIconButton(_ symbol: String) -> NSButton {
        let btn = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
            target: self, action: nil)
        btn.bezelStyle = .inline
        btn.isBordered = false
        return btn
    }

    private func separator() -> NSView {
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 20))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        return v
    }

    // MARK: - 事件

    @objc private func toolTapped(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < AnnotationTool.allCases.count else { return }
        let tool = AnnotationTool.allCases[idx]
        if selectedTool == tool {
            // 再次点击已选中工具 → 取消选择（退出绘制模式），回到"无工具"状态
            selectedTool = nil
            onToolDeselected?()
        } else {
            selectedTool = tool
            onToolChanged?(tool)
        }
    }

    /// 弹出系统颜色拾取面板。
    @objc private func pickColor() {
        let panel = NSColorPanel.shared
        panel.color = selectedColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.orderFront(nil)
        // 叠层窗口 level=.screenSaver，面板必须同级或更高才能显示在叠层之上
        panel.level = .screenSaver
    }

    @objc private func colorPicked(_ sender: NSColorPanel) {
        selectedColor = sender.color
        onColorChanged?(selectedColor)
    }

    // MARK: - 绑定操作

    func bindActions(undo: @escaping () -> Void,
                     done: @escaping () -> Void,
                     copy: @escaping () -> Void,
                     pin: @escaping () -> Void,
                     cancel: @escaping () -> Void) {
        onUndo = undo; onDone = done; onCopy = copy; onPin = pin; onCancel = cancel
        undoButton.action = #selector(actUndo)
        doneButton.action  = #selector(actDone)
        copyButton.action  = #selector(actCopy)
        pinButton.action   = #selector(actPin)
        cancelButton.action = #selector(actCancel)
    }

    @objc private func actUndo()   { onUndo?() }
    @objc private func actDone()   { onDone?() }
    @objc private func actCopy()   { onCopy?() }
    @objc private func actPin()    { onPin?() }
    @objc private func actCancel() { onCancel?() }

    // MARK: - 高亮

    private func updateToolButtons() {
        for (i, btn) in toolButtons.enumerated() {
            let active = (AnnotationTool.allCases[i] == selectedTool)
            btn.contentTintColor = active ? .controlAccentColor : .labelColor
            if active {
                // 选中态：accent 色背景圆角
                btn.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                btn.layer?.cornerRadius = 6
            } else {
                btn.layer?.backgroundColor = nil
            }
        }
    }
}
