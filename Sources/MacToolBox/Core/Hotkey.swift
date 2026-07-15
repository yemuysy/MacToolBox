import Foundation
import AppKit

/// 全局快捷键（Carbon 物理键码 + 修饰键掩码）。
/// 纯数据结构，可 Codable，便于单元测试与持久化。
///
/// 注意：`modifiers` 使用 Carbon 的 EventModifiers 数值（与 Cocoa 的 NSEvent.ModifierFlags 不同），
/// 在 `HotkeyService` 中负责与 NSEvent 互转。
struct Hotkey: Codable, Hashable, Sendable {
    /// 物理键码（与键盘布局无关）
    var keyCode: UInt32
    /// Carbon 风格修饰键掩码
    var modifiers: UInt32

    static let none = Hotkey(keyCode: 0, modifiers: 0)
    var isNone: Bool { keyCode == 0 }

    /// Carbon 修饰键掩码常量
    static let cmd     = UInt32(0x0100)
    static let shift   = UInt32(0x0200)
    static let option  = UInt32(0x0800)
    static let control = UInt32(0x1000)

    /// 人类可读描述，例如 "⌘⇧4"
    var displayString: String {
        Self.modifierSymbols(modifiers) + (keyCode == 0 ? "" : Self.keyName(keyCode))
    }

    static func modifierSymbols(_ mods: UInt32) -> String {
        var s = ""
        if mods & Self.cmd != 0     { s += "⌘" }
        if mods & Self.shift != 0   { s += "⇧" }
        if mods & Self.option != 0  { s += "⌥" }
        if mods & Self.control != 0 { s += "⌃" }
        return s
    }

    /// 将 NSEvent.ModifierFlags 转换为 Carbon 掩码
    static func from(cocoa mods: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if mods.contains(.command)   { m |= Self.cmd }
        if mods.contains(.shift)     { m |= Self.shift }
        if mods.contains(.option)    { m |= Self.option }
        if mods.contains(.control)   { m |= Self.control }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
            11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
            18:"1",19:"2",20:"3",21:"4",22:"5",23:"6",24:"7",25:"8",26:"9",27:"0",
            29:"]",30:"\\",33:"[",35:"=",37:"-",
            36:"↩",48:"Tab",49:"Space",51:"⌫",53:"Esc",
            122:"F1",123:"F2",124:"F3",125:"F4",126:"F5",127:"F6",128:"F7",129:"F8",130:"F9",131:"F10",132:"F11",133:"F12"
        ]
        if let name = map[code] { return name }
        return "键\(code)"
    }
}

/// 快捷键触发的动作。新增动作只需追加 case。
enum HotkeyAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case regionScreenshot
    case fullScreenshot
    case windowScreenshot
    case pinScreenshot
    case toggleMainWindow
    case openOverview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regionScreenshot:  return "区域截图"
        case .fullScreenshot:    return "全屏截图"
        case .windowScreenshot:  return "窗口截图"
        case .pinScreenshot:     return "截图并贴图"
        case .toggleMainWindow:  return "显示 / 隐藏主窗口"
        case .openOverview:      return "打开概览"
        }
    }

    /// 默认绑定（用户未自定义时使用）
    var `default`: Hotkey {
        switch self {
        case .regionScreenshot:  return Hotkey(keyCode: 4,  modifiers: Hotkey.cmd | Hotkey.shift)  // ⇧⌘4
        case .fullScreenshot:    return Hotkey(keyCode: 3,  modifiers: Hotkey.cmd | Hotkey.shift)  // ⇧⌘3
        case .windowScreenshot:  return Hotkey(keyCode: 4,  modifiers: Hotkey.cmd | Hotkey.shift | Hotkey.option) // ⇧⌥⌘4
        case .pinScreenshot:     return Hotkey(keyCode: 5,  modifiers: Hotkey.cmd | Hotkey.shift | Hotkey.option) // ⇧⌥⌘5
        case .toggleMainWindow:  return Hotkey.none
        case .openOverview:      return Hotkey.none
        }
    }
}
