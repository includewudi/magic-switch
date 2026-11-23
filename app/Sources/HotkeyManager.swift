import Carbon.HIToolbox
import Foundation

/// Carbon 全局热键：⌃⌥S → studio，⌃⌥M → mini
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onHotkey: ((String) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var installed = false
    private var handler: EventHandlerRef?

    private let signature = OSType(0x4D475737) // 'MGS7'

    func install() {
        guard !installed else { return }
        installed = true

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let userData {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let names = ["studio", "mini"]
                manager.onHotkey?(names[Int(hkID.id - 1) % names.count])
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)

        register(keyCode: UInt32(kVK_ANSI_S), id: 1) // ⌃⌥S
        register(keyCode: UInt32(kVK_ANSI_M), id: 2) // ⌃⌥M
    }

    private func register(keyCode: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let mods = UInt32(controlKey | optionKey)
        RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }
}
