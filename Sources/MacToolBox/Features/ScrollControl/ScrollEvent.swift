import CoreGraphics
import Foundation

/// 滚轮事件相关的常量 + 纯逻辑（可单测）+ CGEvent 字段读写。
/// 反向/触控板判定/平滑步进的核心算法与 `CGEvent` 解耦，便于沙盒测试。
enum ScrollEvent {

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

    /// 读取该滚动事件是否来自触控板。
    static func isTrackpad(_ event: CGEvent) -> Bool {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        return classifyIsTrackpad(isContinuous: continuous, momentumPhase: momentum, scrollPhase: phase)
    }

    /// 对纵轴（Axis1）三种增量表示统一取反。
    static func reverseVerticalAxis(_ event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1,
                                   value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,
                                   value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                  value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
    }

    /// 对横轴（Axis2）三种增量表示统一取反。
    static func reverseHorizontalAxis(_ event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2,
                                   value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2,
                                   value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                  value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
    }

    /// 提取像素级增量基准（供平滑使用）。优先 pointDelta，退化到 fixedPt 行增量 * 每行像素估值。
    static func pixelDelta(_ event: CGEvent, axis1: Bool) -> Double {
        let pointField: CGEventField = axis1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let fixedField: CGEventField = axis1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let point = Double(event.getIntegerValueField(pointField))
        if point != 0 { return point }
        return event.getDoubleValueField(fixedField) * 10.0  // 每行约 10px 估值
    }
}
