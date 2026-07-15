import CoreGraphics
import Foundation

/// 平滑滚动合成器（移植 Mos 思路）。
/// 把一次原始滚轮增量累加进每轴 remaining 缓冲，60Hz 定时器按 step 比例插值，
/// 逐帧 post 像素级滚动事件；自合成事件打 `syntheticMagic` 标记，避免被自身 tap 二次拦截。
///
/// 线程模型：所有 remaining 读写用 NSLock 保护；定时器挂主 RunLoop，post 亦在主线程。
final class ScrollPoster: @unchecked Sendable {
    static let shared = ScrollPoster()

    private let lock = NSLock()
    private var remainingV: Double = 0
    private var remainingH: Double = 0
    private var step: Double = 0.3
    private var timer: Timer?
    private let source = CGEventSource(stateID: .hidSystemState)

    // 亚像素残余：Int32 取整会丢小数，累积回缓冲避免尾部卡住。
    private var carryV: Double = 0
    private var carryH: Double = 0

    private init() {}

    /// 追加一次滚动目标（已含反向与加速度），并确保定时器运行。
    func enqueue(deltaV: Double, deltaH: Double, step: Double) {
        lock.lock()
        self.step = step
        remainingV += deltaV
        remainingH += deltaH
        lock.unlock()
        ensureTimer()
    }

    /// 立即停止并清空（功能关闭时调用）。
    func reset() {
        lock.lock()
        remainingV = 0; remainingH = 0; carryV = 0; carryH = 0
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    private func ensureTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    private func tick() {
        lock.lock()
        let s = step
        let (dv, newV, doneV) = ScrollEvent.smoothTick(remaining: remainingV, step: s)
        let (dh, newH, doneH) = ScrollEvent.smoothTick(remaining: remainingH, step: s)
        remainingV = newV
        remainingH = newH
        // 累加亚像素残余
        carryV += dv
        carryH += dh
        let emitV = carryV.rounded(.towardZero)
        let emitH = carryH.rounded(.towardZero)
        carryV -= emitV
        carryH -= emitH
        let done = doneV && doneH
        lock.unlock()

        if emitV != 0 || emitH != 0 {
            postPixel(dv: emitV, dh: emitH)
        }

        if done {
            DispatchQueue.main.async { [weak self] in
                self?.timer?.invalidate()
                self?.timer = nil
            }
        }
    }

    private func postPixel(dv: Double, dh: Double) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(dv)),   // 纵向
            wheel2: Int32(clamping: Int(dh)),   // 横向
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: ScrollEvent.syntheticMagic)
        event.post(tap: .cghidEventTap)
    }
}
