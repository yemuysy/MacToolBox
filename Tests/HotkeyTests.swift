import Foundation
import AppKit

/// Hotkey 编解码与展示测试
enum HotkeyTests {
    static func run() {
        print("Hotkey:")
        let hk = Hotkey(keyCode: 4, modifiers: Hotkey.cmd | Hotkey.shift)
        if let data = try? JSONEncoder().encode(hk),
           let dec = try? JSONDecoder().decode(Hotkey.self, from: data) {
            check(dec.keyCode == 4 && dec.modifiers == (Hotkey.cmd | Hotkey.shift), "Hotkey Codable 往返")
        } else {
            check(false, "Hotkey 编解码失败")
        }

        let d = Hotkey(keyCode: 3, modifiers: Hotkey.cmd | Hotkey.shift)
        check(d.displayString.contains("⌘") && d.displayString.contains("⇧"), "displayString 含修饰符")
        check(d.displayString.contains("F"), "displayString 含键名(F): \(d.displayString)")
        check(Hotkey.none.isNone, "Hotkey.none.isNone")

        let m = Hotkey.from(cocoa: NSEvent.ModifierFlags(arrayLiteral: .command, .shift))
        check(m == (Hotkey.cmd | Hotkey.shift), "from(cocoa:) 正确转换")
    }
}
