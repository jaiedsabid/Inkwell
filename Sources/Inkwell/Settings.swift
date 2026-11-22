import AppKit
import Carbon.HIToolbox
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
    case anthropic, openai, gemini, openrouter, ollama
    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama"
        }
    }

    /// One line under the picker.
    var blurb: String {
        switch self {
        case .anthropic: "Claude models. Get a key at console.anthropic.com."
        case .openai: "GPT models. Get a key at platform.openai.com."
        case .gemini: "Gemini models. Get a key at aistudio.google.com."
        case .openrouter: "One key for hundreds of models from many companies. Get a key at openrouter.ai."
        case .ollama: "Models running on this Mac in the Ollama app. No key needed; nothing leaves your Mac."
        }
    }

    var needsKey: Bool { self != .ollama }
    var isLocal: Bool { self == .ollama }

    var defaultCheckModel: String {
        switch self {
        case .anthropic: "claude-haiku-5-5"
        case .openai: "gpt-5-mini"
        case .gemini: "gemini-flash-latest"
        case .openrouter: "openrouter/auto"
        case .ollama: ""
        }
    }

    var defaultChatModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-5"
        case .gemini: "gemini-pro-latest"
        case .openrouter: "openrouter/auto"
        case .ollama: ""
        }
    }

    var keyPrefixHint: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai: "sk-…"
        case .gemini: "AIza…"
        case .openrouter: "sk-or-…"
        case .ollama: ""
        }
    }
}

/// Which models to use with a provider: a fast one for live checks, a stronger one for chat.
struct ModelChoice: Codable, Equatable {
    var check: String
    var chat: String
}

/// The "improve selected text" shortcut: a key plus Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// What the key shows as, e.g. "Space" or "I".
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")

    var label: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return key.count > 1 ? s + " " + key : s + key
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, key }

    /// Also reads the fixed choices older versions saved ("optionSpace", …).
    init(from decoder: Decoder) throws {
        if let old = try? decoder.singleValueContainer().decode(String.self) {
            switch old {
            case "ctrlOptionSpace": self.init(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), key: "Space")
            case "cmdShiftSpace": self.init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), key: "Space")
            case "ctrlOptionI": self.init(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | optionKey), key: "I")
            default: self = .default
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try c.decode(UInt32.self, forKey: .keyCode), modifiers: try c.decode(UInt32.self, forKey: .modifiers),
                  key: try c.decode(String.self, forKey: .key))
    }

    /// Builds a shortcut from a key press. Needs ⌘, ⌥ or ⌃ (⇧ alone would block typing), except for F-keys.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let fKey = Self.fKeys[code]
        guard fKey != nil || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.shift) { mods |= shiftKey }
        let name = fKey ?? Self.named[code] ?? Self.character(for: event)
        guard let name, !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: UInt32(mods), key: name)
    }

    private static func character(for event: NSEvent) -> String? {
        // ⌥ changes the character ("π" for P), so read the key without modifiers.
        guard let c = event.charactersIgnoringModifiers?.uppercased(), let first = c.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(first) else { return nil }
        return c
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
    ]
    private static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
    ]
}

/// All user settings, saved in UserDefaults as they change.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // General
    @Published var enabled: Bool { didSet { save("enabled", enabled) } }
    @Published var pausedUntil: Date? { didSet { save("pausedUntil", pausedUntil) } }
    @Published var hotkey: Shortcut { didSet { save("hotkey", hotkey) } }
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
    /// Gray next-word suggestions after the cursor.
    @Published var autocomplete: Bool { didSet { save("autocomplete", autocomplete) } }
    @Published var completionLength: CompletionLength { didSet { save("completionLength", completionLength) } }

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
    @Published var provider: Provider { didSet { save("provider", provider) } }
    /// Model choices per provider, so switching back and forth keeps them.
    @Published var modelChoices: [String: ModelChoice] { didSet { save("modelChoices", modelChoices) } }
    /// Address of the Ollama server.
    @Published var ollamaURL: String { didSet { save("ollamaURL", ollamaURL) } }

    var checkModel: String {
        get { modelChoices[provider.rawValue]?.check ?? provider.defaultCheckModel }
        set { modelChoices[provider.rawValue, default: ModelChoice(check: provider.defaultCheckModel, chat: provider.defaultChatModel)].check = newValue }
    }
    var chatModel: String {
        get { modelChoices[provider.rawValue]?.chat ?? provider.defaultChatModel }
        set { modelChoices[provider.rawValue, default: ModelChoice(check: provider.defaultCheckModel, chat: provider.defaultChatModel)].chat = newValue }
    }
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
        hotkey = load("hotkey", Shortcut.default)
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
        autocomplete = load("autocomplete", true)
        completionLength = load("completionLength", .phrase)
        appTones = load("appTones", [:])
        disabledApps = load("disabledApps", Self.defaultDisabledApps)
        disabledSites = load("disabledSites", [])
        dictionary = load("dictionary", [])
        ignoredSuggestions = load("ignoredSuggestions", [])
        disabledKinds = load("disabledKinds", [])
        engine = load("engine", .cloud)
        provider = load("provider", .anthropic)
        var choices = load("modelChoices", [String: ModelChoice]())
        // Settings from before per-provider choices: keep the models picked for the current provider.
        if choices.isEmpty, let check = UserDefaults.standard.data(forKey: "checkModel").flatMap({ try? JSONDecoder().decode(String.self, from: $0) }),
           let chat = UserDefaults.standard.data(forKey: "chatModel").flatMap({ try? JSONDecoder().decode(String.self, from: $0) }) {
            choices[load("provider", Provider.anthropic).rawValue] = ModelChoice(check: check, chat: chat)
        }
        modelChoices = choices
        ollamaURL = load("ollamaURL", "http://localhost:11434")
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
