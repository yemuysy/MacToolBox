import Foundation

/// ScrollControl 纯逻辑沙盒测试：触控板判定 / 反向 / 平滑步进 / 配置默认值。
/// 不触碰真实 CGEvent（需运行时权限），只验证与事件解耦的算法。
enum ScrollEventTests {
    static func run() {
        print("ScrollControl:")

        // MARK: 触控板判定
        check(!ScrollEvent.classifyIsTrackpad(isContinuous: false, momentumPhase: 0, scrollPhase: 0),
              "离散鼠标滚轮 → 非触控板")
        check(ScrollEvent.classifyIsTrackpad(isContinuous: true, momentumPhase: 0, scrollPhase: 0),
              "连续事件 → 触控板")
        check(ScrollEvent.classifyIsTrackpad(isContinuous: false, momentumPhase: 2, scrollPhase: 0),
              "存在惯性相位 → 触控板")
        check(ScrollEvent.classifyIsTrackpad(isContinuous: false, momentumPhase: 0, scrollPhase: 1),
              "存在滚动相位 → 触控板")

        // MARK: 反向
        check(ScrollEvent.reversed(5, if: true) == -5, "启用反向取负")
        check(ScrollEvent.reversed(5, if: false) == 5, "关闭反向不变")
        check(ScrollEvent.reversed(-3, if: true) == 3, "负值反向为正")

        // MARK: 平滑步进
        let t1 = ScrollEvent.smoothTick(remaining: 100, step: 0.3)
        check(abs(t1.delta - 30) < 0.001, "step=0.3 取 30% (\(t1.delta))")
        check(abs(t1.newRemaining - 70) < 0.001, "剩余 70 (\(t1.newRemaining))")
        check(!t1.done, "未完成")

        let t2 = ScrollEvent.smoothTick(remaining: 0.5, step: 0.3)
        check(t2.delta == 0.5 && t2.newRemaining == 0 && t2.done, "尾部小量一次清空并完成")

        let t3 = ScrollEvent.smoothTick(remaining: 0, step: 0.3)
        check(t3.done && t3.delta == 0, "剩余 0 直接完成")

        // step 越界钳制到 [0.05, 0.95]
        let t4 = ScrollEvent.smoothTick(remaining: 100, step: 5.0)
        check(t4.delta <= 95.0001, "step 超界钳制 (\(t4.delta))")

        // 收敛性：反复步进后必定归零
        var remaining = 250.0
        var iterations = 0
        while true {
            let r = ScrollEvent.smoothTick(remaining: remaining, step: 0.25)
            remaining = r.newRemaining
            iterations += 1
            if r.done { break }
            if iterations > 1000 { break }
        }
        check(remaining == 0 && iterations < 1000, "平滑步进有限步内收敛 (\(iterations) 步)")

        // MARK: 配置默认值
        let cfg = ConfigStore.ScrollControlConfig()
        check(!cfg.enabled, "默认不启用拦截")
        check(cfg.reverseVertical, "默认纵向反向开")
        check(!cfg.reverseHorizontal, "默认横向反向关")
        check(cfg.smooth, "默认平滑开")
        check(cfg.excludeTrackpad, "默认触控板豁免开")
        check(cfg.smoothStep == 0.3, "默认平滑度 0.3")
        check(cfg.smoothSpeed == 3.0, "默认加速度 3.0")

        // 常量标记非零，避免被误判为普通事件
        check(ScrollEvent.syntheticMagic != 0, "自合成标记非零")
    }
}
