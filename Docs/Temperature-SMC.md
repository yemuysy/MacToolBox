# CPU 温度读取（Apple Silicon SMC）

> 模块：`Sources/MacToolBox/Utilities/SMCReader.swift`
> 调用：`Sources/MacToolBox/Services/SystemInfoService.swift`
> 显示：`Sources/MacToolBox/Views/OverviewView.swift`（概览页「温度」卡）+ `MenuBarPanelView.swift`（菜单栏面板）

---

## 1. 结论速览

- **Apple Silicon（M 系列）上，普通用户进程（uid 501）即可读取 SMC 温度，不需要 root、不需要特权 helper。**
- 移植自 [Stats (exelban/stats)](https://github.com/exelban/stats) `SMC/smc.swift` 的读取逻辑：精确内存布局 `SMCKeyData_t` + 两步读协议（selector=2）。
- 显示值 = **多核心 die 传感器平均** + **EMA 时间平滑**，对齐 Tencent Lemon / iStat 的呈现方式，idle 约 43–45°C，压测平滑爬升到 60+°C。

> ⚠️ 早期曾误判「M 系列未授权进程读 SMC 被系统封锁，必须装特权 helper」。这是旧 `SMCReader` 用了错误的结构体布局 + 单次 `selector=5` 调用导致全 nil，被误读成「封锁」。**已推翻**，验证见第 4 节。

---

## 2. 架构

```
SystemInfoService.update()       (每 ~2s 一次，CPU/内存/网络/磁盘)
SystemInfoService.updateTemperature()  (每 ~5s 一次，独立于主轮询)
        │
        ▼
SMCReader.cpuTemperature()  ── 普通用户态，无特权
        │   ① 遍历 coreTempKeys，对每个键 getValue()
        │   ② 过滤 <20°C（门控假值）与 ≥110°C（异常）
        │   ③ 对有效键值求平均
        ▼
   返回 Double?  (nil = 本次读不到)
        │
        ▼
SystemInfoService  EMA 平滑  (prev*0.7 + temp*0.3)
        │   nil 时保留上一次有效值，不覆盖
        ▼
snap.temperature  →  OverviewView / MenuBarPanelView 显示（nil 显示「—」）
```

---

## 3. SMC 读取核心（对齐 Stats）

`SMCKeyData_t` 精确字段顺序（stride = 80 字节）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `key` | UInt32 | 4 字符键名（如 `"Tp0D"`）|
| `vers` | vers_t | 版本信息 |
| `pLimitData` | LimitData_t | 功率限制 |
| `keyInfo` | keyInfo_t | 含 `dataSize` / `dataType` |
| `padding` | UInt16 | |
| `result` / `status` | UInt8 | |
| `data8` | UInt8 | 命令码：9=取键信息，5=读字节 |
| `data32` | UInt32 | |
| `bytes` | 32×UInt8 | 返回数据 |

**两步读协议**（selector 恒为 2 = `kSMCHandleFunction`）：

1. `input.data8 = 9`（`kSMCGetKeyInfo`）→ 拿到该键的 `dataSize` 与 `dataType`
2. 回填 `input.keyInfo.dataSize`，`input.data8 = 5`（`kSMCReadBytes`）→ 拿到 `bytes`

`dataType` 常见为 `flt`（直接按 `Float(bitPattern:)` 解析），也兼容 `sp78`/`ui16`/`fpe2` 等（见 `getValue` 的 switch）。

---

## 4. 踩坑记录（关键，别重蹈）

### Bug 1：`typeString` 把 `flt` 拼成 `"flt "`
- SMC 类型码是 4 字节字符。本机实测 `flt` 的 raw 是 `666C7420`——**第 4 字节是空格 `0x20`，不是空字节 `\0`**。
- 第一版用 `String(bytes:encoding:)` 拼出 `"flt\u{0}"`；改成过滤可见字符时又把范围写成 `0x20...0x7E`（含空格），于是输出 `"flt "`。
- 后果：`switch val.dataType` 的 `case "flt"` **永远不匹配** → 全 `nil`。
- **正确写法**：可见字符范围 `0x21...0x7E`（排除空格与控制字符）。

### Bug 2：冷启动偶发空读
- 进程首次 SMC 读取偶发返回空（ds=0）。
- **修复**：整组扫描重试 3 轮，每次间隔 50ms。

### Bug 3：电源门控假值导致均值剧跳
- M 系列核心 die 在 idle 休眠（电源门控）时，对应温度传感器会读出 **~5.2°C** 的占位假值；活跃时才报真实温度。
- 后果：若对所有核心简单平均，idle 时均值被拉到 ~20°C，压测时又飙到 60+，剧烈跳变。
- **修复**：过滤 `<20°C` 的读数（只保留活跃核心），再求平均。

### 早期误判（已推翻）
- 旧代码用错误的 `SMCParamStruct` 布局 + 单次 `selector=5` 调用，每次返回 `kr=-536870206`，被误读成「系统封锁未授权进程读 SMC」。
- 实测：换用 Stats 的正确布局 + selector=2 两步读后，`IOServiceOpen` 成功且能读到真实温度。**Apple Silicon 普通用户态可读 SMC 温度，不需要特权 helper。**

---

## 5. 显示策略（对齐 Lemon / iStat）

1. **多核心平均**：遍历 30 个核心 die 温度键（`Tp0*/Tc0*/Te0*/Tg0*`，M4 Pro 实测有效），过滤门控假值后求均值。idle 稳定 ~41.5°C。
2. **EMA 时间平滑**：`smoothed = prev*0.7 + temp*0.3`。抹平核心门控进出导致的偶发阶梯跳变。
3. **nil 兜底**：某次读不到（罕见 SMC 超时）时，保留上一帧有效值，UI 不闪「—」。

### 实机验证（M4 Pro, idle → 压测 → 回落）

| 状态 | 显示值 (EMA) | 原始多核均值 |
|------|-------------|-------------|
| idle 起手 | 45.1°C | 45.1 |
| 压测中 | 50 → 55 → 58 → 61 → 63（平滑爬升）| 62 → 66（硬跳，被 EMA 抹平）|
| 停压回落 | 缓慢降到 58 | 瞬间掉回 41.9 |

对比 Tencent Lemon 同机显示 **43°C**，差值 2°C 属不同软件键权重差异，正常。

---

## 6. 维护注意

- **加新机型**：若换到非 M4 的芯片，先用 `smc_survey` 风格脚本枚举全部 `T*` 键，确认 `coreTempKeys` 列表仍有效（不同代 Apple Silicon 的 SMC 键名会变）。
- **不要回退成单键**：单键瞬时值波动大（40↔66），多核心平均 + EMA 才是稳定方案。
- **不要加特权 helper**：当前方案已验证普通用户态可读，加 helper 反而增加权限复杂度。
