# 鼠标滚轮控制实现架构

> 模块：`Sources/MacToolBox/Features/ScrollControl/`

---

## 1. 整体架构

通过 `CGEventTap` 全局拦截鼠标滚轮事件，按用户配置（反向/平滑）处理后重新注入事件流。所有逻辑在主进程内完成，不依赖任何外部进程或辅助工具。

```
CGEventTap (全局事件监听)
     │
     │ scrollWheel 事件到达
     ▼
ScrollEngine.filter(event:)
     │
     ├─ ① 跳过自合成事件（magic 标记）
     ├─ ② 跳过触控板事件（启用了触控板豁免时）
     ├─ ③ 按配置反向 delta
     ├─ ④ 若开启平滑 → 交由 ScrollPoster 插值合成
     │                  └─ 否则直接反向后 post 回系统
     ▼
由 ScrollPoster 或直接 CGEventPost 将事件送回系统事件流
```

## 2. Event Tap

`CGEventTap` 在 `CGSSessionEventTap` 层级、`headInsertEventTap` 位置拦截 `CGEventMaskBit(kCGEventScrollWheel)` 事件。由 `ScrollEngine` 管理：

- **tap-keeper**（2.5 秒定时器）：检测 tap 是否被系统禁用（`.tapDisabledByTimeout`），自动重启
- **冷却机制**：60 秒内最多重启 3 次，超出则停止尝试，防止系统权限弹窗自锁
- tap 创建函数 `tapCreate` 回调不在主线程，引擎内部用 `@unchecked Sendable` + actor 隔离保证 Swift 6 严格并发安全

## 3. 触控板识别（启发式）

通过 `CGEvent` 的以下字段组合判断事件来源是否为触控板：

| 判定依据 | 触控板特征 | 鼠标特征 |
|---------|-----------|---------|
| `isContinuous` | 是（连续滚动）| 否（逐行滚动）|
| `momentumPhase` | 非零（惯性阶段）| 始终为 0 |
| `scrollPhase` | 非零（滚动阶段）| 始终为 0 |

识别出的触控板事件直接放行（跳过拦截），保持原生滚动手感。

## 4. 反向逻辑

对 `CGEvent` 的三个 delta 表示分别取反：

- `kCGScrollWheelEventDeltaAxis1`（纵向）
- `kCGScrollWheelEventDeltaAxis2`（横向）
- `kCGScrollWheelEventPointDeltaAxis1` / `kCGScrollWheelEventPointDeltaAxis2`（像素级）

纵向反向和横向反向独立开关。

## 5. 平滑滚动（ScrollPoster）

`ScrollPoster` 将一次原始滚轮事件拆解为多帧小增量，模拟惯性滚动。

### 工作机制

1. 收到一次原始滚动 delta，存入每轴的 `remaining` 缓冲区
2. 60Hz 定时器驱动：每帧从 `remaining` 中按 `step` 比例（默认 0.3）取出部分增量
3. 合成新的 `CGEvent(scrollWheelEvent2Source:units: .pixel)` 事件
4. 自合成事件带 `eventSourceUserData == magic` 标记，引擎过滤时直接跳过，避免二次进入管线
5. 当 `remaining` 趋近于 0 时停止定时器

### 参数

| 参数 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| `smoothStep` | 0.3 | 0.1~0.9 | 每帧消耗剩余量的比例（越大越跟手） |
| `smoothSpeed` | 3.0 | 1~10 | 原始 delta 放大倍率 |

## 6. 权限

- 需 **辅助功能权限**（Accessibility）：`AXIsProcessTrusted()`
- 未授权时 tap 创建失败，`ScrollEngine` 返回 `.tapDisabledByTimeout` 状态
- UI 提供引导按钮：打开「系统设置 → 隐私与安全性 → 辅助功能」
- 也支持 `AXIsProcessTrustedWithOptions` 弹窗申请（标准系统弹窗）

## 7. 与 Mos 的区别

本实现参照 [Caldis/Mos](https://github.com/Caldis/Mos) 的核心逻辑，但做了简化：

| 特性 | Mos | 本实现 |
|------|-----|--------|
| 按 App 单独配置 | ✅ | ❌（全局配置） |
| 滚动热键 | ✅ | ❌ |
| 平滑插值 | ✅ | ✅（简化版）|
| tap-keeper + 冷却 | ✅ | ✅ |
| 触控板豁免 | ✅ | ✅ |
| 反向独立开关 | ✅ | ✅ |

## 8. 文件清单

| 文件 | 角色 |
|------|------|
| `ScrollControlService.swift` | UI 层控制器 + 引擎启动/停止 |
| `ScrollEvent.swift` | 事件过滤、反向、触控板判定、delta 解析等纯函数 |
| `ScrollPoster.swift` | 像素级插值合成 + 60Hz 定时器驱动 |
| `ScrollControlView.swift` | 设置 UI + 权限引导 |
