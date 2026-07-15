# MacToolBox 新增两大功能 — 实施计划

> 参考真实开源项目源码：Finder 右键增强参照 [`wflixu/RClick`](https://github.com/wflixu/RClick)，鼠标滚轮反向 + 平滑滚动参照 [`Caldis/Mos`](https://github.com/Caldis/Mos)。
>
> 决策（已与用户确认）：**先实现 Phase 1 滚轮控制，后实现 Phase 2 右键增强**；本计划随仓库留存。

---

## 一、功能 A：Finder 右键增强（参照 RClick · 完整套件）

### 1. 功能清单（6 项，对齐 RClick）

| 功能 | 说明 | 执行位置 |
|---|---|---|
| 新建文件 | txt/md/json/csv 等，右键空白处或目录生成模板文件 | 主程序 |
| 复制路径 | 选中文件/文件夹绝对路径写入剪贴板 | 主程序 |
| 用 App 打开 | 用户可配置的 App 列表，对选中项打开 | 主程序 |
| 直接删除 | 跳过废纸篓删除（带确认） | 主程序 |
| 隐藏/显示 | 设置 `UF_HIDDEN` 标志 | 主程序 |
| 常用目录 | 书签目录子菜单，一键打开 | 主程序 |

### 2. 核心架构（来自 RClick 真实代码）

- **必须新增独立 Finder Sync 扩展**（`FinderSyncExt.appex` 子 bundle）。这是 macOS 注入 Finder 右键菜单的**唯一官方途径**。
- **瘦扩展模式**：扩展本身只做两件事——渲染菜单 + 转发点击事件。真正的文件操作全在主程序。
- **IPC 机制**：`DistributedNotificationCenter` + Codable JSON（带签名校验 `MessageSecurity`）。
  - 主程序 → 扩展：`menuConfig`（菜单配置）、`running`（启动通知）、`quit`
  - 扩展 → 主程序：`click`（点击）、`heartbeat`（10s 心跳）、`requestConfig`（缓存失效时主动要）
  - 扩展 `init` 时 `requestMenuConfig()`；配置变更即推送；心跳保活。
- **扩展实现要点**（源自 `FinderSyncExt.swift`）：
  - `FIFinderSync` 子类，`directoryURLs = ["/"]` 全盘监听。
  - `menu(for:)` 读 `cachedMenuConfig` 动态建 `NSMenu`（动作/App/新建文件/常用目录四组，支持折叠成子菜单）。
  - 点击时 `FIFinderSyncController.default().selectedItemURLs()` 拿选中项，`targetedURL()` 拿空白处目标目录，构造 `ClickEventPayload` 发回主程序。

### 3. 文件改动清单

**新增**
- `Sources/FinderSyncExt/FinderSyncExt.swift`（扩展主体）
- `Sources/FinderSyncExt/Info.plist`（`NSExtension` 声明）
- `Sources/Shared/RightClickShared.swift`（消息类型 + `Messager`，**主程序与扩展共用**）
- `Sources/MacToolBox/Features/RightClick/RightClickService.swift`（配置 + 接收 click + 分派）
- `Sources/MacToolBox/Features/RightClick/RightClickModels.swift`（Action/App/NewFileType/CommonDir 实体）
- `Sources/MacToolBox/Features/RightClick/RightClickActionHandlers.swift`（6 个动作执行）
- `Sources/MacToolBox/Features/RightClick/RightClickView.swift`（设置 UI，作为主窗口 Tab）

**修改**
- `build.sh`：分别编译主程序与扩展（共享 `RightClickShared` 编入两者），组装 `.appex`，**最后 codesign 两者**
- `AppDelegate.swift`：启动后向扩展推 `menuConfig` + 注册 `click` 处理器
- `ConfigStore.swift`：持久化右键配置（App 列表 / 新建类型 / 常用目录 / 动作开关）
- `FeatureID.swift` / `FeatureManager.swift`：加 `rightClick` 功能 id

### 4. 权限

- **Finder 扩展需在「系统设置 → 隐私与安全性 → 扩展 → Finder」手动启用**（最大用户阻力点）→ 设置页提供引导按钮（打开系统设置对应面板 + 图文指引）。

---

## 二、功能 B：鼠标滚轮反向 + 平滑滚动（参照 Mos）✅ 本期实现

### 1. 功能清单（选「反向 + 平滑」）

| 功能 | 说明 |
|---|---|
| 主开关 | 全局启用/停用拦截 |
| 纵向反向 / 横向反向 | 独立开关，对滚轮 delta 取反 |
| 平滑滚动 | 插值合成（平滑度 step / 加速度 speed 两参数） |
| 触控板豁免 | 自动识别并跳过触控板（保持原生手感） |
| 按 App 配置 / 滚动热键 | **可选增强**（完整 Mos 才有），本期先留接口 |

### 2. 核心架构（来自 Mos 真实代码 `ScrollCore`/`Interceptor`/`ScrollEvent`）

- **主程序内 `CGEventTap`** 拦截 `scrollWheel` 事件：
  - `tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: 1<<scrollWheel)`
  - 回调里：① 跳过自己合成的平滑事件（`eventSourceUserData == magic`）；② **跳过触控板**（`isContinuous || momentumPhase != 0 || scrollPhase != 0` 启发式）；③ 鼠标事件按配置对 `scrollWheelEventDeltaAxis1/2`（及 point/fixedPt 三种表示）取反；④ 若开启平滑，交给 `ScrollPoster` 用 `CGEventSource` + 定时器合成插值事件回送。
- **`ScrollPoster`（平滑核心，移植 Mos 思路）**：维护每轴 remaining 缓冲，60Hz 定时器按 `step` 比例把一次原始滚动插值成多帧小增量像素事件 `CGEvent(scrollWheelEvent2Source:units:.pixel...)` post，复用「自合成事件打 magic 标记避免二次进入管线」机制。
- **tap-keeper（移植 Mos `Interceptor`）**：2.5s 定时器 + 回调内 `.tapDisabledByTimeout` 双保险，被系统禁用（TCC 弹窗/超时）时自动重启；带 60s 窗口 3 次上限**冷却**防自锁（关键稳定性机制）。

### 3. 文件改动清单

**新增**
- `Sources/MacToolBox/Features/ScrollControl/ScrollControlService.swift`（`ScrollEngine` 非隔离 tap 引擎 + `ScrollControlService` @MainActor UI 层）
- `Sources/MacToolBox/Features/ScrollControl/ScrollEvent.swift`（delta 反向 + 触控板判定 + 平滑步进等纯函数，可单测）
- `Sources/MacToolBox/Features/ScrollControl/ScrollPoster.swift`（像素级插值合成）
- `Sources/MacToolBox/Features/ScrollControl/ScrollControlView.swift`（主窗口 Tab UI + 权限引导）
- `Tests/ScrollEventTests.swift`（纯逻辑沙盒测试）

**修改**
- `ConfigStore.swift`：存 `ScrollControlConfig{enabled/reverseVertical/reverseHorizontal/smooth/smoothStep/smoothSpeed/excludeTrackpad}`
- `AppDelegate.swift`：启动时若功能启用则 `ScrollControlService.shared.startIfEnabled()`
- `FeatureID.swift` / `FeatureManager.swift`：加 `scrollControl` 功能 id（默认关闭，需授权）
- `build.sh` / `test.sh`：追加 `-framework CoreGraphics -framework ApplicationServices`

### 4. 权限

- **辅助功能权限**（`AXIsProcessTrusted()`）：未授权则停止 tap 并通知；设置页提供引导按钮打开「系统设置 → 隐私与安全性 → 辅助功能」，并支持 `AXIsProcessTrustedWithOptions` 弹窗申请。

---

## 三、关键约束 / 风险

1. **Finder Sync 扩展必须代码签名**（Apple Silicon 强制）：主程序与扩展须用相同身份，`CFBundleVersion` 一致。开发期 ad-hoc `codesign -s -`，分发需 Developer ID。（Phase 2）
2. **扩展需用户手动启用**（系统设置 → 扩展 → Finder）——体验阻力点，必须有引导 UI。（Phase 2）
3. **build.sh 需改造**：swiftc 分两次编译（主程序 / 扩展，共享消息类型编入两者）→ 组装 `.appex` → 嵌入 `MacToolBox.app/Contents/PlugIns/` → 最后 `codesign` 二者。（Phase 2）
4. 当前主程序**未启用 sandbox**，扩展也走 unsandboxed，无沙盒冲突。
5. 触控板识别是启发式，无法区分 Magic Mouse / 黑苹果触控板（Mos 已知限制，可接受）。
6. 滚轮拦截需**辅助功能权限**，首启动会弹 TCC，keeper 冷却机制避免反复弹窗自锁。

## 四、实施顺序

- **Phase 0 脚手架** ✅：FeatureManager 加 id；ConfigStore 加配置字段；主窗口加 Tab。
- **Phase 1 滚轮反向+平滑** ✅（本期）：event tap + 反向 + 平滑 + 触控板豁免 + 权限引导 + 单测。
- **Phase 2 右键增强**（后续）：FinderSyncExt + 共享消息层 + 主程序 manager/handlers + 设置 + **build.sh 改造 + codesign**。
- **Phase 3 联调 + 文档**：README 更新；`./build.sh` 零警告 + `./test.sh` 不回归。
