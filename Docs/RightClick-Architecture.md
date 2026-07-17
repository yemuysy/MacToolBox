# Finder 右键增强实现架构

> 模块：`Sources/MacToolBox/Features/RightClick/`
> 扩展：`Sources/FinderSyncExt/`
> 共享 IPC + 配置：`Sources/Shared/RightClickShared.swift`
> 免费路线：`Resources/Info.plist` 的 `NSServices` 声明

---

## 1. 整体架构（对标开源：RightKit / SaneClick / Flicker）

右键增强采用**双进程架构**：一个独立的 Finder Sync 扩展注入右键菜单，主程序负责执行实际文件操作。
同时提供 **NSServices「服务」子菜单**作为免签名免费路线。

```
┌─ Finder 进程 ──────────────────────┐
│  Finder Sync 扩展 (FinderSyncExt)  │
│  ┌─────────────────────────────┐   │
│  │ FIFinderSync 子类            │   │
│  │ menu(for:) → 构建 NSMenu     │   │
│  │ handleAction → 点击转发      │   │
│  └──────────┬──────────────────┘   │
└─────────────┼──────────────────────┘
              │ DistributedNotificationCenter
              │ (带 SHA256 签名校验)
              ▼
┌─ MacToolBox 主进程 ─────────────────┐
│  RightClickService                  │
│   - 接收点击事件                     │
│   - 分派到 RightClickActionHandlers │
│   - 发布菜单配置（通知 + App Group） │
│  ┌─────────────────────────────┐    │
│  │ RightClickActionHandlers    │    │
│  │ 10 个动作的执行逻辑          │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

## 2. 瘦扩展模式

扩展本身（Finder Sync 插件）**只做两件事**：

1. **渲染菜单** — `menu(for:)` 从 App Group 共享文件 / 缓存的 `RCMenuConfig` 动态构建 NSMenu
2. **转发点击** — `handleAction(_:)` 将点击事件序列化为 `RCClickPayload` 发回主程序

所有文件操作权限、UI 弹窗、业务逻辑**全部在主进程执行**。这降低了扩展的复杂度，也避免了沙盒扩展的权限限制。

## 3. 配置下发（开源标准双机制）

配置来源对标 RightKit / SaneClick / Flicker——**App Group 共享容器内的 `menu.json` 落盘**：

1. **App Group 文件（主机制）**：每次配置变更，`RightClickService.publishMenuConfig()` 把 `RCMenuConfig`
   写入 `group.com.yemu.mactoolbox` 共享容器的 `rightclick_menu.json`。
   扩展在 `menu(for:)` 时直接读文件渲染，**Finder 重启后依然稳定**，无需等待主程序通知。
2. **分布式通知（实时刷新）**：同时 `RCMessager.post(.menuConfig)` 立即刷新已运行的扩展缓存。

两条路径扩展都能拿到最新菜单，互为兜底。

## 4. IPC 通信

通过 `DistributedNotificationCenter` + JSON 序列化通信。通知名以 App Group ID 为前缀（`group.com.yemu.mactoolbox.rightclick`），确保沙盒化的扩展能正确收发。

### 消息协议

| 方向 | 消息类型 | 说明 |
|------|---------|------|
| 主 → 扩展 | `menuConfig` | 推送完整菜单配置（JSON） |
| 主 → 扩展 | `running` | 通知扩展主程序已启动 |
| 主 → 扩展 | `quit` | 通知扩展主程序退出 |
| 扩展 → 主 | `click` | 用户点击了菜单项 |
| 扩展 → 主 | `heartbeat` | 10 秒心跳保活 |
| 扩展 → 主 | `requestConfig` | 扩展请求最新配置 |

### 签名校验

每条消息携带 `SHA256(payload + secret)` 签名，扩展与主程序内联同一份密钥，防止其他进程伪造点击注入。

## 5. 心跳与存活检测

- 扩展每 **10 秒**发送心跳
- 主程序每 **15 秒**检查一次，`lastContact` 超过 30 秒未更新则标记 `extensionAlive = false`
- 状态在 UI 中显示为"已接入"（绿色）或"待启用扩展"（橙色）

## 6. 十个动作实现

| 动作 | 执行逻辑 | 文件 |
|------|---------|------|
| 新建文件 | 在目标目录生成空文件，同名自动加序号 | `RightClickActionHandlers.swift` |
| 从模板新建 | 复制模板目录里的文件到当前目录（RightKit 标志性功能） | `RightClickActionHandlers.swift` |
| 复制路径 | 选中项绝对路径写入剪贴板 | `RightClickActionHandlers.swift` |
| 复制文件名 | 选中项文件名（不含路径）写入剪贴板 | `RightClickActionHandlers.swift` |
| 用 App 打开 | 通过 NSWorkspace 以指定 bundleID 的 App 打开 | `RightClickActionHandlers.swift` |
| 在终端打开 | `open -b <bundleID> <dir>` 在终端定位到目录 | `RightClickActionHandlers.swift` |
| 在 Finder 中显示 | `activateFileViewerSelecting` 定位选中项 | `RightClickActionHandlers.swift` |
| 直接删除 | 跳过废纸篓，带系统路径守卫（`/System`/`/usr` 等不可删）和确认弹窗 | `RightClickActionHandlers.swift` |
| 隐藏/显示 | 切换 UF_HIDDEN 标志位 | `RightClickActionHandlers.swift` |
| 打开常用目录 | 在 Finder 中打开用户预设的目录 | `RightClickActionHandlers.swift` |

## 7. 免费路线：NSServices（免签名）

`Resources/Info.plist` 的 `NSServices` 声明把同名动作注册到 Finder 右键「服务」子菜单，
由 `AppDelegate.rightClickService` 经 `NSPortName` 接收、复用 `RightClickActionHandlers` 执行。
**无需证书、无需启用扩展**，但受 macOS 设计限制只能出现在「服务」子菜单（无法置顶一级菜单）。
要一级菜单仍须用 Finder Sync 扩展（需签名）。

## 8. 关键约束

- **Finder Sync 扩展必须代码签名**：Apple Silicon 强制要求有效签名，否则 `pluginkit` 不会注册扩展。开发期 ad-hoc 签名不足以让扩展出现在「系统设置 → 扩展 → Finder」中。
- **用户需手动启用扩展**：放入 `/Applications` 后需在系统设置中开启一次。
- **App Group 必须一致**：主程序与扩展的 entitlements 中 `com.apple.security.application-groups` 必须包含相同的 App Group ID（`group.com.yemu.mactoolbox`）。
- 主程序**非沙盒**，扩展**沙盒化**，通过 App Group 跨沙盒通信。

## 9. 文件清单

| 文件 | 角色 |
|------|------|
| `Sources/FinderSyncExt/FinderSyncExt.swift` | Finder Sync 扩展主体 |
| `Sources/FinderSyncExt/Info.plist` | 扩展声明（`NSExtension` 配置） |
| `Sources/Shared/RightClickShared.swift` | IPC 消息类型 + RCMessager（签名+收发）+ RCAppGroup（menu.json 读写） |
| `Sources/MacToolBox/Features/RightClick/RightClickService.swift` | 主程序侧服务（监听+发布+分派） |
| `Sources/MacToolBox/Features/RightClick/RightClickModels.swift` | 配置模型（RightClickConfig） |
| `Sources/MacToolBox/Features/RightClick/RightClickActionHandlers.swift` | 动作执行器 |
| `Sources/MacToolBox/Features/RightClick/RightClickView.swift` | 设置 UI |
| `Resources/Info.plist` | `NSServices` 免费路线声明 |
