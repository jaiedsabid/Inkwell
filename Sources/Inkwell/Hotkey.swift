import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon hot keys need no extra permission).
@MainActor
final class Hotkey: ObservableObject {
    static let shared = Hotkey()
    /// The shortcut couldn't be registered: another app (Alfred, ChatGPT, Raycast…) already uses it.
    @Published private(set) var taken = false
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    var action: (() -> Void)?

    /// Apps that may already hold ⌥ Space. macOS doesn't report a clash between apps (the first to register gets the
    /// key and the other stays silent), so Inkwell can only warn when one of them is running.
    static let knownOptionSpaceApps: [(id: String, name: String)] = [
        ("com.runningwithcrayons.Alfred", "Alfred"), ("com.openai.chat", "ChatGPT"),
        ("com.raycast.macos", "Raycast"), ("com.anthropic.claudefordesktop", "Claude"),
    ]

    /// A running app that may use the same shortcut, unless the user said it's fine.
    func likelyClash(for shortcut: Shortcut) -> String? {
        guard shortcut == .default else { return nil }
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: "hotkeyClashDismissed") ?? [])
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.knownOptionSpaceApps.first { running.contains($0.id) && !dismissed.contains($0.id) }?.name
    }

    func dismissClash(_ name: String) {
        guard let id = Self.knownOptionSpaceApps.first(where: { $0.name == name })?.id else { return }
        var list = UserDefaults.standard.stringArray(forKey: "hotkeyClashDismissed") ?? []
        list.append(id)
        UserDefaults.standard.set(list, forKey: "hotkeyClashDismissed")
        objectWillChange.send()
    }

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
        if taken != (status != noErr) { taken = status != noErr }
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
