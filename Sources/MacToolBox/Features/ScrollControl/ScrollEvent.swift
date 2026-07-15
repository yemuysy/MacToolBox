import CoreGraphics
import Foundation
import OSLog

/// 滚轮事件相关的常量 + 纯逻辑（可单测）+ CGEvent 字段读写。
/// 反向/触控板判定/平滑步进的核心算法与 `CGEvent` 解耦，便于沙盒测试。
enum ScrollEvent {

    private static let log = OSLog(subsystem: "com.yemu.mactoolbox", category: "ScrollEvent")

    // MARK: - 常量

    /// 自合成平滑事件的标记值（'MTBX'）。写入 `eventSourceUserData`，
    /// event tap 回调据此跳过自己发出的插值事件，避免二次进入管线造成死循环。
    static let syntheticMagic: Int64 = 0x4D54_4258

    // MARK: - 纯逻辑（单测覆盖）

    /// 触控板判定启发式（移植 Mos）：连续事件 / 存在滚动相位 / 存在惯性相位 任一成立即视为触控板。
    /// 鼠标滚轮为离散行事件，三者恒为 0。
    static func classifyIsTrackpad(isContinuous: Bool, momentumPhase: Int64, scrollPhase: Int64) -> Bool {
        isContinuous || momentumPhase != 0 || scrollPhase != 0
    }

    /// 反向：对单轴增量取反。
    static func reversed(_ value: Double, if enabled: Bool) -> Double {
        enabled ? -value : value
    }

    /// 平滑单帧步进：从 remaining 里按 step 比例取出一份增量。
    /// 当剩余量已很小（<= minStep）时一次性清空，避免尾部无限逼近导致定时器长跑。
    /// 返回 (本帧增量, 更新后剩余量, 是否已完成)。
    static func smoothTick(remaining: Double, step: Double, minStep: Double = 1.0) -> (delta: Double, newRemaining: Double, done: Bool) {
        if remaining == 0 { return (0, 0, true) }
        if abs(remaining) <= minStep {
            return (remaining, 0, true)
        }
        let clampedStep = min(max(step, 0.05), 0.95)
        let delta = remaining * clampedStep
        return (delta, remaining - delta, false)
    }

    // MARK: - CGEvent 字段读写

    /// 是否为本 App 自合成的平滑事件。
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMagic
    }

    /// 读取该滚动事件是否来自触控板。附带诊断日志。
    static func isTrackpad(_ event: CGEvent) -> Bool {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let result = classifyIsTrackpad(isContinuous: continuous, momentumPhase: momentum, scrollPhase: phase)
        os_log(.debug, log: log,
               "isTrackpad: continuous=%{bool}d MomentumPhase=%{public}ld ScrollPhase=%{public}ld → %{bool}d",
               continuous, momentum, phase, result)
        return result
    }

    /// 对纵轴（Axis1）三种增量表示统一取反。附带诊断日志。
    static func reverseVerticalAxis(_ event: CGEvent) {
        let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let p1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let f1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -d1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -p1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -f1)
        os_log(.debug, log: log,
               "reverseV: delta %{public}.d→%{public}.d point %{public}.d→%{public}.d fixed %.2f→%.2f",
               d1, -d1, p1, -p1, f1, -f1)
    }

    /// 对横轴（Axis2）三种增量表示统一取反。附带诊断日志。
    static func reverseHorizontalAxis(_ event: CGEvent) {
        let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let p2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let f2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -d2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -p2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -f2)
        os_log(.debug, log: log,
               "reverseH: delta %{public}.d→%{public}.d point %{public}.d→%{public}.d fixed %.2f→%.2f",
               d2, -d2, p2, -p2, f2, -f2)
    }

    /// 提取像素级增量基准（供平滑使用）。
    ///
    /// 策略：
    /// 1. **pointDelta** — 鼠标通常等于行数(1~3)，需放大到像素；触控板已是真实像素
    /// 2. **fixedPtDelta** — 高精度浮点行数 → 乘以 lineHeightPx（20px，约 macOS 默认行高）
    /// 3. **delta**（整数行数） → 同乘 lineHeightPx 兜底
    ///
    /// 旧代码 fallback 仅用 fixedPt*10 且 pointDelta 直接返回原值，
    /// 导致鼠标每格仅产生 1~3 像素总量，经 smoothStep=0.3 拆分后单帧 <1px 被 Int32 取整吞掉。
    static func pixelDelta(_ event: CGEvent, axis1: Bool) -> Double {
        let pointField: CGEventField = axis1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let fixedField: CGEventField = axis1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let intField: CGEventField = axis1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2

        let point = Double(event.getIntegerValueField(pointField))
        if point != 0 {
            // 鼠标的 pointDelta 通常就是行数（1~3），需要放大到像素；
            // 触控板的 pointDelta 已经是真实像素（几十~几百），保持不变
            let px = abs(point) < 5 ? point * 20.0 : point
            os_log(.debug, log: log,
                   "pixelDelta(axis%{public}@): pointDelta=%.1f → %.1fpx (abs<5→行转像素)",
                   axis1 ? "1" : "2", point, px)
            return px
        }
        let fixed = event.getDoubleValueField(fixedField)
        if fixed != 0.0 {
            let px = fixed * 20.0
            os_log(.debug, log: log,
                   "pixelDelta(axis%{public}@): fixedPtDelta=%.2f → %.1fpx",
                   axis1 ? "1" : "2", fixed, px)
            return px
        }
        let intVal = Double(event.getIntegerValueField(intField))
        os_log(.debug, log: log,
               "pixelDelta(axis%{public}@): delta=%{public}.d → %.1fx (last resort)",
               axis1 ? "1" : "2", Int(intVal), intVal * 20.0)
        return intVal * 20.0
    }

    /// 转储原始事件所有滚动字段（诊断用）。
    static func dumpFields(_ event: CGEvent) -> String {
        let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let p1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let p2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let f1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let f2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        return String(format:
            "d1=%d d2=%d p1=%d p2=%d f1=%.3f f2=%.3f cont=%d mom=%ld phase=%ld srcUD=%lld",
            d1, d2, p1, p2, f1, f2,
            event.getIntegerValueField(.scrollWheelEventIsContinuous),
            event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            event.getIntegerValueField(.scrollWheelEventScrollPhase),
            event.getIntegerValueField(.eventSourceUserData))
    }
}
