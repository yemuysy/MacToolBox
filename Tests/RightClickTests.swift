import Foundation

/// 右键增强：IPC 签名、配置映射、点击负载 round-trip 的纯逻辑测试。
struct RightClickTests {
    static func run() {
        print("== RightClick IPC / 配置 测试 ==")

        // 默认配置
        let cfg = RightClickConfig()
        check(cfg.enabled == false, "RightClickConfig 默认未启用")
        check(cfg.newFileTypes == ["txt", "md", "json", "csv"], "默认新建类型")
        check(cfg.showNewFile && cfg.showCopyPath && cfg.showOpenWith, "默认动作开关")

        // 签名 round-trip
        let payload = "hello-world"
        let sig = RCMessager.sign(payload)
        check(RCMessager.verify(payload: payload, signature: sig), "签名校验通过")
        check(!RCMessager.verify(payload: payload, signature: "tampered"), "篡改签名被拒")

        // 菜单配置映射
        var c = RightClickConfig()
        c.enabled = true
        c.newFileTypes = ["txt", "md"]
        let menu = RCMenuConfig(from: c)
        check(menu.enabled == true, "RCMenuConfig.enabled 映射")
        check(menu.newFileTypes == ["txt", "md"], "RCMenuConfig 类型映射")
        if let j = menu.toJSON(),
           let back = try? JSONDecoder().decode(RCMenuConfig.self, from: Data(j.utf8)) {
            check(back.enabled == true, "RCMenuConfig 解码还原")
        } else {
            check(false, "RCMenuConfig 编码/解码")
        }

        // 点击负载 round-trip
        let click = RCClickPayload(
            item: "copyPath",
            targets: ["file:///tmp/a.txt"],
            targetedDir: "file:///tmp",
            subItem: nil
        )
        if let j = click.toJSON(), let back = RCClickPayload(json: j) {
            check(back.item == "copyPath" && back.targets.count == 1, "RCClickPayload round-trip")
        } else {
            check(false, "RCClickPayload round-trip")
        }
    }
}
