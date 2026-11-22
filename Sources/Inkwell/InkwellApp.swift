import AppKit
import Combine
import SwiftUI

@main
struct InkwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: settings.isActive ? "pencil.line" : "pencil.slash")
        }
        .menuBarExtraStyle(.window)
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
        if CommandLine.arguments.contains("--aitest") { Task { exit(await SelfTest.aiTest() ? 0 : 1) }; return }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(to: CommandLine.arguments[i + 1]); exit(0)
        }

        let settings = AppSettings.shared
        Coordinator.shared.start()
        Hotkey.shared.action = { ChatController.shared.open() }
        settings.$hotkey.sink { Hotkey.shared.register($0) }.store(in: &bag)

        // Clear an expired pause so the menu bar icon updates.
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let p = settings.pausedUntil, p <= Date() { settings.pausedUntil = nil }
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
            w.center()
            settingsWindow = w
        }
        present(settingsWindow!)
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
            w.center()
            onboardingWindow = w
        }
        present(onboardingWindow!)
    }

    private func present(_ w: NSWindow) {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }
}
