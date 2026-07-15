import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 引擎配置快照（Sendable，安全跨线程传给 C 回调）

struct ScrollEngineConfig: Sendable {
    var reverseVertical: Bool
    var reverseHorizontal: Bool
    var smooth: Bool
    var smoothStep: Double
    var smoothSpeed: Double
    var excludeTrackpad: Bool

    static let disabled = ScrollEngineConfig(
        reverseVertical: false, reverseHorizontal: false,
        smooth: false, smoothStep: 0.3, smoothSpeed: 3, excludeTrackpad: true
    )
}

// MARK: - CGEventTap 引擎（非隔离，回调需同步返回事件指针）

/// 滚轮拦截引擎（移植 Mos `ScrollCore`/`Interceptor`）。
/// 非隔离单例：event tap 回调在主 RunLoop 线程同步执行、必须同步返回事件指针，
/// 故不能用 @MainActor 的 async。配置快照与 keeper 状态用 NSLock 保护。
final class ScrollEngine: @unchecked Sendable {
    static let shared = ScrollEngine()

    private let lock = NSLock()
    private var config: ScrollEngineConfig = .disabled
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keeper: Timer?

    // keeper 冷却：60s 窗口内自动重启超过 3 次则判定异常，停止避免自锁
    private var reEnableTimestamps: [TimeInterval] = []
    private(set) var isCoolingDown = false

    private init() {}

    // MARK: 配置

    func updateConfig(_ cfg: ScrollEngineConfig) {
        lock.lock(); config = cfg; lock.unlock()
    }

    private func currentConfig() -> ScrollEngineConfig {
        lock.lock(); defer { lock.unlock() }; return config
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return tap != nil
    }

    // MARK: 启停

    /// 创建并启用 tap。需已授予辅助功能权限，否则返回 false。
    @discardableResult
    func enable() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        lock.lock()
        if tap != nil { lock.unlock(); return true }
        isCoolingDown = false
        reEnableTimestamps.removeAll()
        lock.unlock()

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollEventTapCallback,
            userInfo: nil
        ) else {
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)

        lock.lock()
        tap = t
        runLoopSource = src
        lock.unlock()

        startKeeper()
        Logger.shared.info("ScrollEngine enabled")
        return true
    }

    func disable() {
        lock.lock()
        let t = tap
        let src = runLoopSource
        tap = nil
        runLoopSource = nil
        lock.unlock()

        if let t { CGEvent.tapEnable(tap: t, enable: false) }
        if let src { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        stopKeeper()
        ScrollPoster.shared.reset()
        Logger.shared.info("ScrollEngine disabled")
    }

    // MARK: 事件处理（回调线程同步执行）

    /// 返回 nil 表示消费事件（平滑模式由 poster 合成回送）；否则原样/修改后放行。
    func process(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let cfg = currentConfig()

        // 1. 跳过自合成平滑事件
        if ScrollEvent.isSynthetic(event) {
            return Unmanaged.passUnretained(event)
        }
        // 2. 触控板豁免
        if cfg.excludeTrackpad, ScrollEvent.isTrackpad(event) {
            return Unmanaged.passUnretained(event)
        }
        // 3. 反向（对三种增量表示统一取反）
        if cfg.reverseVertical { ScrollEvent.reverseVerticalAxis(event) }
        if cfg.reverseHorizontal { ScrollEvent.reverseHorizontalAxis(event) }

        // 4. 平滑：消费原事件，改由 poster 插值回送
        if cfg.smooth {
            let dv = ScrollEvent.pixelDelta(event, axis1: true) * cfg.smoothSpeed
            let dh = ScrollEvent.pixelDelta(event, axis1: false) * cfg.smoothSpeed
            if dv != 0 || dh != 0 {
                ScrollPoster.shared.enqueue(deltaV: dv, deltaH: dh, step: cfg.smoothStep)
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// 回调内收到 tap 被系统禁用（超时/用户输入）时同步重启。
    func handleTapDisabled() {
        lock.lock(); let t = tap; lock.unlock()
        guard let t else { return }
        if registerReEnable() {
            CGEvent.tapEnable(tap: t, enable: true)
        }
    }

    // MARK: keeper（周期巡检 + 冷却）

    private func startKeeper() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let exists = self.keeper != nil; self.lock.unlock()
            if exists { return }
            let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
                self?.keeperTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.lock.lock(); self.keeper = timer; self.lock.unlock()
        }
    }

    private func stopKeeper() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let k = self.keeper; self.keeper = nil; self.lock.unlock()
            k?.invalidate()
        }
    }

    private func keeperTick() {
        lock.lock(); let t = tap; lock.unlock()
        guard let t else { return }
        if !CGEvent.tapIsEnabled(tap: t) {
            if registerReEnable() {
                CGEvent.tapEnable(tap: t, enable: true)
                Logger.shared.info("ScrollEngine tap re-enabled by keeper")
            }
        }
    }

    /// 记录一次重启并检查冷却。返回是否允许本次重启。
    private func registerReEnable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isCoolingDown { return false }
        let now = Date().timeIntervalSince1970
        reEnableTimestamps.append(now)
        reEnableTimestamps = reEnableTimestamps.filter { now - $0 <= 60 }
        if reEnableTimestamps.count > 3 {
            isCoolingDown = true
            Logger.shared.info("ScrollEngine entered cooldown (too many re-enables)")
            return false
        }
        return true
    }
}

// MARK: - C 回调（模块级，无捕获，可作 CGEventTapCallBack）

private func scrollEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        ScrollEngine.shared.handleTapDisabled()
        return Unmanaged.passUnretained(event)
    case .scrollWheel:
        return ScrollEngine.shared.process(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - UI 层服务（@MainActor，驱动引擎 + 权限）

/// 滚轮控制的 UI 侧门面：持久化配置、驱动 `ScrollEngine`、管理辅助功能权限状态。
@MainActor
final class ScrollControlService: ObservableObject {
    static let shared = ScrollControlService()

    @Published var config: ConfigStore.ScrollControlConfig
    @Published private(set) var running = false
    @Published private(set) var accessibilityGranted = false

    private init() {
        config = ConfigStore.shared.scrollControlConfig()
        accessibilityGranted = AXIsProcessTrusted()
    }

    private var engineConfig: ScrollEngineConfig {
        ScrollEngineConfig(
            reverseVertical: config.reverseVertical,
            reverseHorizontal: config.reverseHorizontal,
            smooth: config.smooth,
            smoothStep: config.smoothStep,
            smoothSpeed: config.smoothSpeed,
            excludeTrackpad: config.excludeTrackpad
        )
    }

    /// App 启动时调用：功能启用且已授权则拉起拦截。
    func startIfEnabled() {
        ScrollEngine.shared.updateConfig(engineConfig)
        guard config.enabled else { return }
        _ = enableInterception()
    }

    @discardableResult
    func enableInterception() -> Bool {
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted else { running = false; return false }
        ScrollEngine.shared.updateConfig(engineConfig)
        running = ScrollEngine.shared.enable()
        return running
    }

    func disableInterception() {
        ScrollEngine.shared.disable()
        running = false
    }

    /// 主开关。
    func setEnabled(_ on: Bool) {
        config.enabled = on
        persist()
        if on {
            _ = enableInterception()
        } else {
            disableInterception()
        }
    }

    /// 修改参数并热更新到引擎。
    func update(_ mutate: (inout ConfigStore.ScrollControlConfig) -> Void) {
        mutate(&config)
        persist()
        ScrollEngine.shared.updateConfig(engineConfig)
    }

    // MARK: 权限

    func refreshPermission() {
        accessibilityGranted = AXIsProcessTrusted()
        running = ScrollEngine.shared.isRunning
    }

    /// 弹系统授权提示（首次引导）。
    /// 直接用字符串常量（Swift 6 下全局 CF var `kAXTrustedCheckOptionPrompt` 非并发安全）。
    func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
    }

    /// 打开系统设置 → 隐私与安全性 → 辅助功能。
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func persist() {
        ConfigStore.shared.setScrollControlConfig(config)
    }
}
