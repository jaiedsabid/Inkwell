import AppKit
import Sparkle

/// Software updates, done by Sparkle. It reads the feed named in Info.plist (`SUFeedURL`, the appcast attached to the latest
/// GitHub release), checks each download against the public key in Info.plist (`SUPublicEDKey`), replaces the app and relaunches
/// it. Automatic checks only look: nothing is installed unless the user says so.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController
    private var observers: [NSKeyValueObservation] = []

    /// False while a check or an installation is already running.
    @Published private(set) var canCheck = false
    /// Mirrors Sparkle's own setting, which it keeps in the user defaults.
    @Published var checksAutomatically: Bool {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != checksAutomatically {
                controller.updater.automaticallyChecksForUpdates = checksAutomatically
            }
        }
    }
    @Published private(set) var lastChecked: Date?

    private init() {
        // Sparkle only works inside a real app bundle. From a bare binary (a development build, the self-test or the snapshot
        // tool) it would show an "updater failed to start" alert, so it stays off there.
        let inBundle = Bundle.main.bundleURL.pathExtension == "app"
            && !CommandLine.arguments.contains(where: { $0.hasPrefix("--") })
        controller = SPUStandardUpdaterController(startingUpdater: inBundle, updaterDelegate: nil, userDriverDelegate: nil)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        lastChecked = controller.updater.lastUpdateCheckDate
        canCheck = inBundle && controller.updater.canCheckForUpdates
        observers = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] u, _ in
                let value = u.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
            controller.updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] u, _ in
                let value = u.lastUpdateCheckDate
                Task { @MainActor in self?.lastChecked = value }
            },
        ]
    }

    /// Looks for an update now and shows Sparkle's window with the result.
    func checkForUpdates() {
        StatusMenu.shared.close()
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
