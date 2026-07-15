# 贡献指南

感谢你对 **MacToolBox** 感兴趣！这是一个面向 Apple Silicon 的 macOS 系统工具箱，纯 Swift（Swift 6 严格并发），零第三方依赖，使用 `swiftc` 直接构建。

## 开发环境

- macOS 13.0 (Ventura) 及以上
- Apple Silicon (arm64)
- Command Line Tools（`xcode-select --install`），**无需 Xcode**

## 本地构建与测试

```bash
./build.sh     # 编译并打包 build/MacToolBox.app（零警告）
./test.sh      # 运行沙盒测试（纯逻辑 / 分类 / 白名单 / 分批清理等）
./run.sh open  # 编译并启动
```

新增功能请在 `test.sh` 覆盖的测试层补充对应纯逻辑测试（`Tests/`）。

## 代码规范

- **Swift 6 严格并发**：所有跨线程共享状态必须显式隔离（`@MainActor` / `actor` / `@unchecked Sendable` + 串行队列），禁止隐式数据竞争。
- **主线程零阻塞**：任何 `ShellExecutor` 子进程调用、磁盘 I/O、内核接口（如 SMC）都必须在后台队列执行，仅在主线程更新 `@Published`。
- **零第三方依赖**：如需新能力，优先用系统框架（AppKit / Foundation / IOKit 等）。
- **功能分层**：新增功能请在 `Core/FeatureID.swift` 注册，并在 `Features/<Name>/` 下提供 `XxxService.swift` + `XxxView.swift`。

## 提交约定

- 提交信息用中文或英文均可，说明「做了什么 / 为什么」。
- 性能相关改动请注明瓶颈点与量化收益（如「SMC 读取移出主线程，消除每 5s 主线程阻塞」）。
- 不提交 `build/`、`.DS_Store`、用户运行时数据（见 `.gitignore`）。

## 行为准则

友好、就事论事。欢迎 Issue / PR 讨论功能与修复。
