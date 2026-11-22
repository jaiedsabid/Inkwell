import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon hot keys need no extra permission).
@MainActor
final class Hotkey {
    static let shared = Hotkey()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    var action: (() -> Void)?

    /// The shortcut last asked for, so it can come back after `suspend()`.
    private(set) var current: Shortcut?

    /// Returns false when another app already holds this shortcut.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        current = shortcut
        unregister()
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x494E4B57), id: 1)   // 'INKW'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { ref = nil }
        return status == noErr
    }

    /// Lets the keys through while a new shortcut is being recorded.
    func suspend() { unregister() }
    func resume() { if let current { register(current) } }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
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
