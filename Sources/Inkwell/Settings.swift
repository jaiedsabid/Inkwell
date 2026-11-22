import Foundation
import ServiceManagement

enum EngineKind: String, CaseIterable, Codable, Identifiable {
    case cloud, onDevice
    var id: String { rawValue }
    var label: String { self == .cloud ? "Cloud AI (your key)" : "On-device (private)" }
}

enum Provider: String, CaseIterable, Codable, Identifiable {
    case anthropic, openai
    var id: String { rawValue }
    var label: String { self == .anthropic ? "Anthropic (Claude)" : "OpenAI" }
    var defaultCheckModel: String { self == .anthropic ? "claude-haiku-5-5" : "gpt-5-mini" }
    var defaultChatModel: String { self == .anthropic ? "claude-opus-5-5" : "gpt-5" }
    var keyPrefixHint: String { self == .anthropic ? "sk-ant-…" : "sk-…" }
}

enum HotkeyPreset: String, CaseIterable, Codable, Identifiable {
    case optionSpace, ctrlOptionSpace, cmdShiftSpace, ctrlOptionI
    var id: String { rawValue }
    var label: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .ctrlOptionSpace: "⌃⌥ Space"
        case .cmdShiftSpace: "⇧⌘ Space"
        case .ctrlOptionI: "⌃⌥ I"
        }
    }
}

/// All user settings, saved in UserDefaults as they change.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // General
    @Published var enabled: Bool { didSet { save("enabled", enabled) } }
    @Published var pausedUntil: Date? { didSet { save("pausedUntil", pausedUntil) } }
    @Published var hotkey: HotkeyPreset { didSet { save("hotkey", hotkey) } }
    @Published var checkDelay: Double { didSet { save("checkDelay", checkDelay) } }
    @Published var onboarded: Bool { didSet { save("onboarded", onboarded) } }

    // Writing
    @Published var languageCode: String { didSet { save("languageCode", languageCode) } }
    @Published var tone: Tone { didSet { save("tone", tone) } }

    // AI
    @Published var engine: EngineKind { didSet { save("engine", engine) } }
    @Published var provider: Provider {
        didSet {
            save("provider", provider)
            if oldValue != provider { checkModel = provider.defaultCheckModel; chatModel = provider.defaultChatModel }
        }
    }
    @Published var checkModel: String { didSet { save("checkModel", checkModel) } }
    @Published var chatModel: String { didSet { save("chatModel", chatModel) } }

    private init() {
        func load<T: Decodable>(_ key: String, _ def: T) -> T {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
            return v
        }
        enabled = load("enabled", true)
        pausedUntil = load("pausedUntil", nil as Date?)
        hotkey = load("hotkey", .optionSpace)
        checkDelay = load("checkDelay", 0.7)
        onboarded = load("onboarded", false)
        languageCode = load("languageCode", Self.defaultLanguage())
        tone = load("tone", .natural)
        engine = load("engine", .cloud)
        provider = load("provider", .anthropic)
        checkModel = load("checkModel", Provider.anthropic.defaultCheckModel)
        chatModel = load("chatModel", Provider.anthropic.defaultChatModel)
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        d.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func defaultLanguage() -> String {
        let pref = Locale.preferredLanguages.first ?? "en-US"
        if let exact = WritingLanguage.all.first(where: { $0.code == pref }) { return exact.code }
        let base = String(pref.prefix(2))
        return WritingLanguage.all.first(where: { $0.code.hasPrefix(base) })?.code ?? "en-US"
    }

    // MARK: Derived

    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }
    /// True when Inkwell should check text right now.
    var isActive: Bool { enabled && !isPaused }
    var language: WritingLanguage { WritingLanguage.find(languageCode) }

    func pause(for seconds: TimeInterval) { pausedUntil = Date().addingTimeInterval(seconds) }
    func pauseUntilTomorrow() {
        let cal = Calendar.current
        pausedUntil = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))
    }
    func resume() { pausedUntil = nil; enabled = true }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSLog("Inkwell: launch at login failed: \(error)") }
        }
    }
}
