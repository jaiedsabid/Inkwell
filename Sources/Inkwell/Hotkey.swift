import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon hot keys need no extra permission).
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    var action: (() -> Void)?

    func register(_ preset: HotkeyPreset) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        installHandler()
        let (key, mods): (Int, Int) = switch preset {
        case .optionSpace: (kVK_Space, optionKey)
        case .ctrlOptionSpace: (kVK_Space, controlKey | optionKey)
        case .cmdShiftSpace: (kVK_Space, cmdKey | shiftKey)
        case .ctrlOptionI: (kVK_ANSI_I, controlKey | optionKey)
        }
        let id = EventHotKeyID(signature: OSType(0x494E4B57), id: 1)   // 'INKW'
        RegisterEventHotKey(UInt32(key), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.shared.action?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
