import AppKit
import Combine
import SwiftUI

@main
struct InkwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar icon and panel are AppKit (StatusMenu); SwiftUI only needs a scene here.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var pauseTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        if let i = CommandLine.arguments.firstIndex(of: "--localtest"), i + 1 < CommandLine.arguments.count {
            let id = CommandLine.arguments[i + 1]
            Task { let ok = await SelfTest.localTest(id); LlamaEngine.shared.shutdown(); exit(ok ? 0 : 1) }; return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--models"), i + 1 < CommandLine.arguments.count, let p = Provider(rawValue: CommandLine.arguments[i + 1]) {
            Task {
                let list = await ModelLister.fetch(p, key: Keychain.get(p), ollamaURL: AppSettings.shared.ollamaURL)
                print("\(p.label): \(list.count) models"); list.prefix(8).forEach { print("  \($0)") }
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--aitest") { Task { exit(await SelfTest.aiTest() ? 0 : 1) }; return }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(to: CommandLine.arguments[i + 1]); exit(0)
        }

        Log.removeOldFormat()
        let settings = AppSettings.shared
        StatusMenu.shared.install()
        Coordinator.shared.start()
        Hotkey.shared.action = { ChatController.shared.open() }
        settings.$hotkey.sink { Hotkey.shared.register($0) }.store(in: &bag)

        // Clear an expired pause so the menu bar icon updates.
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let p = settings.pausedUntil, p <= Date() { settings.pausedUntil = nil }
                // The app holding the shortcut may have quit: try again.
                if Hotkey.shared.taken { Hotkey.shared.resume() }
            }
        }

        if !settings.onboarded || !AX.isTrusted { showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LlamaEngine.shared.shutdown()
        Stats.shared.save()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { SettingsNav.shared.pane = pane }
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Inkwell Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 760, height: 540))
            settingsWindow = w
        }
        // Centered on the screen with the mouse (where the menu bar icon was clicked), unless already open.
        if let w = settingsWindow, !w.isVisible { center(w) }
        present(settingsWindow!)
    }

    /// Settings → Writing with the tone editor open.
    func showNewTone() {
        showSettings(.writing)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            SettingsNav.shared.editingTone = CustomTone(name: "", guidance: "")
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(finish: { [weak self] in self?.onboardingWindow?.close() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Welcome to Inkwell"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 600, height: 500))
            onboardingWindow = w
        }
        if let w = onboardingWindow, !w.isVisible { center(w) }
        present(onboardingWindow!)
    }

    private func center(_ w: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { w.center(); return }
        let size = w.frame.size
        // A little above the middle, like system windows.
        w.setFrameOrigin(CGPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2 + vis.height * 0.08))
    }

    private func present(_ w: NSWindow) {
        StatusMenu.shared.close()
        // While a window is open, show in the Dock and ⌘Tab like a normal app; back to menu bar only once it closes.
        NSApp.setActivationPolicy(.regular)
        watchClose(w)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private var watched = Set<ObjectIdentifier>()

    private func watchClose(_ w: NSWindow) {
        guard watched.insert(ObjectIdentifier(w)).inserted else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowClosed(w) }
        }
    }

    private func windowClosed(_ closing: NSWindow) {
        let others = [settingsWindow, onboardingWindow].compactMap { $0 }.filter { $0 !== closing && ($0.isVisible || $0.isMiniaturized) }
        guard others.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
