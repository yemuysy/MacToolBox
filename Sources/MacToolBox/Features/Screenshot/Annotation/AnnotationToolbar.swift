import AppKit

// MARK: - 标注工具栏：底部固定，参考 macOS Markup Toolbar 布局。

final class AnnotationToolbar: NSView {

    // MARK: - 状态

    private(set) var selectedTool: AnnotationTool = .rectangle {
        didSet { updateToolButtons() }
    }

    private(set) var selectedColor: NSColor = AnnotationColor.red.nsColor {
        didSet { updateColorButtons() }
    }

    /// 工具切换回调。
    var onToolChanged: ((AnnotationTool) -> Void)?

    /// 颜色切换回调。
    var onColorChanged: ((NSColor) -> Void)?

    /// 撤销按钮点击回调。
    var onUndo: (() -> Void)?

    /// 完成按钮点击回调（用户确认标注，导出图片）。
    var onDone: (() -> Void)?

    /// 复制到剪贴板回调。
    var onCopy: (() -> Void)?

    /// 取消按钮点击回调（丢弃标注）。
    var onCancel: (() -> Void)?

    /// 更新撤销按钮可用状态（外部根据 canvas.canUndo 调用）。
    func setUndoEnabled(_ enabled: Bool) {
        undoButton.isEnabled = enabled
        undoButton.alphaValue = enabled ? 1.0 : 0.35
    }

    /// 贴图到屏幕回调。
    var onPin: (() -> Void)?

    // MARK: - UI 引用

    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private lazy var undoButton = makeIconButton("arrow.uturn.backward", "撤销")
    private lazy var copyButton = makeIconButton("doc.on.doc", "复制")
    private lazy var pinButton   = makeIconButton("pin.fill", "贴图")
    private lazy var doneButton  = makeIconButton("checkmark", "保存")
    private lazy var cancelButton = makeIconButton("xmark", "取消")

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 构建 UI

    private func buildUI() {
        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.spacing = 6
        mainStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        // --- 左侧：工具按钮组 ---
        let toolGroup = NSStackView()
        toolGroup.orientation = .horizontal
        toolGroup.spacing = 3
        for tool in AnnotationTool.allCases {
            let btn = makeToolButton(tool)
            toolButtons.append(btn)
            toolGroup.addArrangedSubview(btn)
        }

        // 分隔线
        let sep1 = separatorView()

        // --- 中间：颜色选择器 ---
        let colorGroup = NSStackView()
        colorGroup.orientation = .horizontal
        colorGroup.spacing = 4
        for ac in AnnotationColor.defaults {
            let btn = makeColorButton(ac)
            colorButtons.append(btn)
            colorGroup.addArrangedSubview(btn)
        }

        // 分隔线
        let sep2 = separatorView()

        // --- 右侧：操作按钮 ---
        let actionGroup = NSStackView()
        actionGroup.orientation = .horizontal
        actionGroup.spacing = 4
        actionGroup.addArrangedSubview(undoButton)
        actionGroup.addArrangedSubview(copyButton)
        actionGroup.addArrangedSubview(pinButton)
        actionGroup.addArrangedSubview(doneButton)
        actionGroup.addArrangedSubview(cancelButton)

        // 组装
        mainStack.addArrangedSubview(toolGroup)
        mainStack.addArrangedSubview(sep1)
        mainStack.addArrangedSubview(colorGroup)
        mainStack.addArrangedSubview(NSView()) // 弹性 spacer
        mainStack.addArrangedSubview(sep2)
        mainStack.addArrangedSubview(actionGroup)

        // 约束：mainStack 填满自身
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 初始状态
        updateToolButtons()
        updateColorButtons()
        setUndoEnabled(false)
    }

    // MARK: - 按钮工厂方法

    private func makeToolButton(_ tool: AnnotationTool) -> NSButton {
        let btn = NSButton(image: NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil)!,
                          target: self, action: #selector(toolTapped(_:)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.toolTip = tool.rawValue
        btn.tag = AnnotationTool.allCases.firstIndex(of: tool)!
        return btn
    }

    private func makeColorButton(_ ac: AnnotationColor) -> NSButton {
        let btn = NSButton(frame: CGRect(origin: .zero, size: NSSize(width: 22, height: 22)))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = ac.nsColor.cgColor
        btn.layer?.cornerRadius = 5
        btn.layer?.borderWidth = 2
        btn.layer?.borderColor = NSColor.clear.cgColor
        btn.toolTip = ac.name
        btn.target = self
        btn.action = #selector(colorTapped(_:))
        return btn
    }

    private func makeIconButton(_ symbol: String, _ tooltip: String) -> NSButton {
        let btn = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
            target: self, action: nil
        )
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.toolTip = tooltip
        return btn
    }

    private func separatorView() -> NSView {
        let v = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 28))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }

    // MARK: - 操作处理

    @objc private func toolTapped(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < AnnotationTool.allCases.count else { return }
        selectedTool = AnnotationTool.allCases[idx]
        onToolChanged?(selectedTool)
    }

    @objc private func colorTapped(_ sender: NSButton) {
        guard let idx = colorButtons.firstIndex(of: sender),
              idx < AnnotationColor.defaults.count else { return }
        selectedColor = AnnotationColor.defaults[idx].nsColor
        onColorChanged?(selectedColor)
    }

    // MARK: - 绑定操作按钮动作（从外部设置）

    func bindActions(undo: @escaping () -> Void,
                     done: @escaping () -> Void,
                     copy: @escaping () -> Void,
                     pin: @escaping () -> Void,
                     cancel: @escaping () -> Void) {
        onUndo = undo
        onDone = done
        onCopy = copy
        onPin = pin
        onCancel = cancel
        undoButton.action = #selector(undoAction)
        doneButton.action  = #selector(doneAction)
        copyButton.action  = #selector(copyAction)
        pinButton.action   = #selector(pinAction)
        cancelButton.action = #selector(cancelAction)
    }

    @objc private func undoAction()   { onUndo?() }
    @objc private func doneAction()   { onDone?() }
    @objc private func copyAction()   { onCopy?() }
    @objc private func pinAction()    { onPin?() }
    @objc private func cancelAction() { onCancel?() }

    // MARK: - 高亮更新

    private func updateToolButtons() {
        for (i, btn) in toolButtons.enumerated() {
            let isActive = (AnnotationTool.allCases[i] == selectedTool)
            btn.layer?.backgroundColor = isActive ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
            btn.layer?.cornerRadius = 6
        }
    }

    private func updateColorButtons() {
        for (i, btn) in colorButtons.enumerated() {
            let isActive = (AnnotationColor.defaults[i].nsColor == selectedColor)
            btn.layer?.borderColor = isActive ? NSColor.white.cgColor : NSColor.clear.cgColor
            if isActive {
                btn.layer?.setAffineTransform(CGAffineTransform(scaleX: 1.15, y: 1.15))
            } else {
                btn.layer?.setAffineTransform(.identity)
            }
        }
    }
}
