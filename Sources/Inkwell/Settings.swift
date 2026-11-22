import AppKit
import ServiceManagement

enum EngineKind: String, CaseIterable, Codable, Identifiable {
    case cloud, local, onDevice
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cloud: "Cloud AI"
        case .local: "Local model"
        case .onDevice: "Apple on-device"
        }
    }
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
    /// Tones the user made. Shown after the built-in ones everywhere a tone can be picked.
    @Published var customTones: [CustomTone] {
        didSet {
            ToneRegistry.custom = customTones
            save("customTones", customTones)
            // A deleted tone falls back to Natural wherever it was used.
            if !tone.exists { tone = .natural }
            let stale = appTones.filter { !$0.value.exists }.map(\.key)
            if !stale.isEmpty { for k in stale { appTones[k] = nil } }
        }
    }
    @Published var autoDetectLanguage: Bool { didSet { save("autoDetectLanguage", autoDetectLanguage) } }
    @Published var strictness: Strictness { didSet { save("strictness", strictness) } }
    @Published var showExplanations: Bool { didSet { save("showExplanations", showExplanations) } }
    /// Purple line when a sentence doesn't fit the tone.
    @Published var toneCheck: Bool { didSet { save("toneCheck", toneCheck) } }
    /// The user's own chat prompts, shown as chips in the chat panel.
    @Published var savedPrompts: [SavedPrompt] { didSet { save("savedPrompts", savedPrompts) } }
    @Published var collectStats: Bool { didSet { save("collectStats", collectStats) } }

    // Apps & privacy
    /// Tone per app, by bundle identifier. Apps not listed use `tone`.
    @Published var appTones: [String: Tone] { didSet { save("appTones", appTones) } }
    @Published var disabledApps: Set<String> { didSet { save("disabledApps", disabledApps) } }
    @Published var disabledSites: Set<String> { didSet { save("disabledSites", disabledSites) } }
    /// Words never flagged (names, slang, product terms).
    @Published var dictionary: [String] { didSet { save("dictionary", dictionary) } }
    /// Suggestions the user chose to always ignore ("original→replacement", lowercased).
    @Published var ignoredSuggestions: [String] { didSet { save("ignoredSuggestions", ignoredSuggestions) } }
    /// Kinds of suggestion the user turned off.
    @Published var disabledKinds: Set<IssueKind> { didSet { save("disabledKinds", disabledKinds) } }

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
    /// The downloaded model in use (catalog id or "hf:owner/repo/file").
    @Published var localModelID: String? { didSet { save("localModelID", localModelID) } }
    /// Models added from Hugging Face by the user.
    @Published var customModels: [LocalModel] { didSet { save("customModels", customModels) } }

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
        let customs = load("customTones", [CustomTone]())
        ToneRegistry.custom = customs
        customTones = customs
        let savedTone = load("tone", Tone.natural)
        tone = savedTone.exists ? savedTone : .natural
        autoDetectLanguage = load("autoDetectLanguage", true)
        strictness = load("strictness", .standard)
        showExplanations = load("showExplanations", true)
        toneCheck = load("toneCheck", true)
        savedPrompts = load("savedPrompts", SavedPrompt.defaults)
        collectStats = load("collectStats", true)
        appTones = load("appTones", [:])
        disabledApps = load("disabledApps", Self.defaultDisabledApps)
        disabledSites = load("disabledSites", [])
        dictionary = load("dictionary", [])
        ignoredSuggestions = load("ignoredSuggestions", [])
        disabledKinds = load("disabledKinds", [])
        engine = load("engine", .cloud)
        provider = load("provider", .anthropic)
        checkModel = load("checkModel", Provider.anthropic.defaultCheckModel)
        chatModel = load("chatModel", Provider.anthropic.defaultChatModel)
        localModelID = load("localModelID", nil as String?)
        customModels = load("customModels", [])
    }

    private func save<T: Encodable>(_ key: String, _ value: T) {
        d.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// Password managers and terminals are off by default.
    static let defaultDisabledApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
    ]

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

    func tone(for bundleID: String?) -> Tone { bundleID.flatMap { appTones[$0] }.flatMap { $0.exists ? $0 : nil } ?? tone }

    func isDisabled(app bundleID: String?, host: String?) -> Bool {
        if let b = bundleID, disabledApps.contains(b) { return true }
        if let h = host?.lowercased() {
            return disabledSites.contains { h == $0 || h.hasSuffix("." + $0) }
        }
        return false
    }

    func addToDictionary(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !dictionary.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        dictionary.append(w)
        NSSpellChecker.shared.learnWord(w)
    }

    var dictionarySet: Set<String> { Set(dictionary.map { $0.lowercased() }) }

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

struct SavedPrompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var instruction: String

    static let defaults: [SavedPrompt] = [
        .init(title: "Polite no", instruction: "Turn this into a polite, friendly way of saying no."),
        .init(title: "Bullet points", instruction: "Turn this into short, clear bullet points."),
        .init(title: "Explain simply", instruction: "Rewrite this so anyone could understand it, without jargon."),
    ]
}
