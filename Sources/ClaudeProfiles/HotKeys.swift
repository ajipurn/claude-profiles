import AppKit
import Carbon.HIToolbox

/// Global ⌘⌥1…⌘⌥9: switch to the Nth profile (panel order). Carbon hotkeys
/// because they are the one global-shortcut API that needs no Accessibility
/// or Input Monitoring permission.
@MainActor
enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []
    private static var handler: ((Int) -> Void)?

    /// `onPress` gets the 0-based profile index.
    static func install(_ onPress: @escaping (Int) -> Void) {
        handler = onPress

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        // C callback — no captures allowed, hence the static handler above.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            Task { @MainActor in HotKeys.handler?(index) }
            return noErr
        }, 1, &pressed, nil, nil)

        // Number-row key codes are not contiguous.
        let digitKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in digitKeys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x4350_484B /* 'CPHK' */, id: UInt32(index))
            RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey), id,
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}
