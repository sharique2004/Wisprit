import Carbon
import Foundation

func tryReg(_ code: UInt32, _ mods: UInt32, _ label: String) {
    var ref: EventHotKeyRef?
    var id = EventHotKeyID(signature: OSType(0x57535054), id: code &+ mods)
    let st = RegisterEventHotKey(code, mods, id, GetEventDispatcherTarget(), 0, &ref)
    print("\(label): keycode=\(code) mods=0x\(String(mods, radix:16)) OSStatus=\(st)")
    if let r = ref { UnregisterEventHotKey(r) }
    _ = id
}
// kVK_Function = 0x3F (63)
tryReg(0x3F, 0, "Fn alone (no modifiers)")
tryReg(0x3F, UInt32(cmdKey), "Fn + Cmd")
tryReg(0x31, 0, "Space alone (no modifiers)")
tryReg(0x31, UInt32(optionKey), "Space + Option only")
tryReg(0x31, UInt32(optionKey|shiftKey), "Space + Shift+Option only")
tryReg(0x31, UInt32(controlKey|optionKey), "Space + Ctrl+Option")
tryReg(0x36, 0, "Right Command alone (kVK_RightCommand 0x36)")
tryReg(0x3D, 0, "Right Option alone (kVK_RightOption 0x3D)")
