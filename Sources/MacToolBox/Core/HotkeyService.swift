import Carbon
import Cocoa
import Foundation

/// 全局快捷键服务（基于 Carbon RegisterEventHotKey，无需辅助功能权限）。
/// 管理 HotkeyAction -> Hotkey 绑定；注册系统级热键；触发时回到主线程分发动作。
///
/// 注意：Carbon 的 RegisterEventHotKey 在 macOS 14+ 被标记为 deprecated，但仍稳定可用，
/// 且是少数无需 Accessibility 权限即可注册全局热键的 API。编译时对整个模块关闭 deprecation 警告。
@MainActor
final class HotkeyService: @unchecked Sendable {
    static let shared = HotkeyService()

    private var bindings: [HotkeyAction: Hotkey] = [:]
    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef?] = [:]
    private var actionToID: [HotkeyAction: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var handlerInstalled = false
    private let signature: FourCharCode = 0x4D544258 // 'MTBX'

    private init() {
        loadBindings()
    }

    // MARK: - 绑定查询 / 修改

    /// 当前生效绑定（用户自定义优先，否则用默认值）
    func effectiveBinding(for action: HotkeyAction) -> Hotkey {
        bindings[action] ?? action.default
    }

    func currentBindings() -> [HotkeyAction: Hotkey] {
        HotkeyAction.allCases.reduce(into: [:]) { $0[$1] = effectiveBinding(for: $1) }
    }

    func setBinding(_ hotkey: Hotkey, for action: HotkeyAction) {
        unregister(action)
        if hotkey.isNone {
            bindings.removeValue(forKey: action)
            ConfigStore.shared.setHotkeyBinding(Hotkey.none, for: action)
        } else {
            bindings[action] = hotkey
            ConfigStore.shared.setHotkeyBinding(hotkey, for: action)
            register(action, hotkey)
        }
        Self.notifyBindingsChanged()
    }

    func resetAll() {
        stop()
        bindings.removeAll()
        ConfigStore.shared.resetHotkeys()
        start()
        Self.notifyBindingsChanged()
    }

    /// 绑定变更通知：主界面（如截图页）可监听以刷新快捷键展示。
    static func notifyBindingsChanged() {
        NotificationCenter.default.post(name: .hotkeyBindingsChanged, object: nil)
    }

    // MARK: - 生命周期

    /// 应用启动时调用：安装事件处理器并注册所有有效绑定
    func start() {
        ensureHandler()
        for action in HotkeyAction.allCases {
            let hk = effectiveBinding(for: action)
            if !hk.isNone { register(action, hk) }
        }
    }

    func stop() {
        for action in HotkeyAction.allCases { unregister(action) }
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
        handlerInstalled = false
    }

    // MARK: - 注册 / 注销

    private func register(_ action: HotkeyAction, _ hotkey: Hotkey) {
        guard hotkey.keyCode != 0 else { return }
        let id = nextID; nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard err == noErr, let ref else { return }
        hotKeyRefs[action] = ref
        actionToID[action] = id
        idMap.set(id, action)
    }

    private func unregister(_ action: HotkeyAction) {
        if let ref = hotKeyRefs[action] {
            UnregisterEventHotKey(ref)
            hotKeyRefs[action] = nil
        }
        if let id = actionToID[action] {
            idMap.remove(id)
            actionToID.removeValue(forKey: action)
        }
    }

    private func ensureHandler() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let err = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if err == noErr { handlerInstalled = true }
    }

    // MARK: - 动作分发（主线程）

    func fire(_ action: HotkeyAction) {
        switch action {
        case .regionScreenshot, .fullScreenshot, .windowScreenshot:
            let mode: CaptureMode = action == .fullScreenshot ? .full
                : (action == .windowScreenshot ? .window : .region)
            ScreenshotFlow.start(mode: mode, pin: false)
        case .pinScreenshot:
            ScreenshotFlow.start(mode: .region, pin: true)
        case .toggleMainWindow:
            (NSApplication.shared.delegate as? AppDelegate)?.toggleMainWindow()
        case .openOverview:
            (NSApplication.shared.delegate as? AppDelegate)?.reveal(feature: .overview)
        }
    }

    // MARK: - 持久化

    private func loadBindings() {
        let stored = ConfigStore.shared.hotkeyBindings()
        for (raw, hk) in stored {
            if let action = HotkeyAction(rawValue: raw) {
                bindings[action] = hk
            }
        }
    }
}

// MARK: - id -> action 映射（C 回调安全访问）

private final class HotkeyIDMap: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [UInt32: HotkeyAction] = [:]
    func get(_ id: UInt32) -> HotkeyAction? {
        lock.lock(); defer { lock.unlock() }
        return map[id]
    }
    func set(_ id: UInt32, _ action: HotkeyAction) {
        lock.lock(); defer { lock.unlock() }
        map[id] = action
    }
    func remove(_ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: id)
    }
}

private let idMap = HotkeyIDMap()

/// Carbon 事件回调（模块级，无捕获上下文，可作 C 函数指针）
private func hotkeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    theEvent: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let theEvent else { return noErr }
    var hkID = EventHotKeyID()
    let err = GetEventParameter(
        theEvent,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )
    guard err == noErr else { return noErr }
    if let action = idMap.get(hkID.id) {
        // 回到主线程分发，避免在非隔离上下文触碰 @MainActor 状态
        DispatchQueue.main.async {
            HotkeyService.shared.fire(action)
        }
    }
    return noErr
}

/// 快捷键绑定变更通知名（主界面监听以刷新展示）。
extension Notification.Name {
    static let hotkeyBindingsChanged = Notification.Name("MacToolBox.HotkeyBindingsChanged")
}
