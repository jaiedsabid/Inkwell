import Combine
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, writing, apps, prompts, privacy, ai, stats
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .writing: "Writing"
        case .apps: "Apps & Websites"
        case .prompts: "Quick Prompts"
        case .stats: "Writing Stats"
        case .privacy: "Dictionary & Privacy"
        case .ai: "AI Engine"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .writing: "textformat"
        case .apps: "square.grid.2x2"
        case .prompts: "bookmark"
        case .stats: "chart.bar"
        case .privacy: "book.closed"
        case .ai: "cpu"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .writing: .blue
        case .apps: .orange
        case .prompts: .pink
        case .stats: .teal
        case .privacy: .green
        case .ai: .purple
        }
    }
}

@MainActor
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var pane: SettingsPane = .general
    /// Opens the tone editor (nil: closed). A tone without a saved match is new.
    @Published var editingTone: CustomTone?
}

struct SettingsView: View {
    @ObservedObject var nav = SettingsNav.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { nav.pane }, set: { if let p = $0 { nav.pane = p } })) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch nav.pane {
                case .general: GeneralPane()
                case .writing: WritingPane()
                case .apps: AppsPane()
                case .prompts: PromptsPane()
                case .stats: StatsPane()
                case .privacy: PrivacyPane()
                case .ai: AIPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(nav.pane.title)
            .sheet(item: $nav.editingTone) { t in ToneEditor(draft: t) }
        }
        .frame(width: 760, height: 540)
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var settings = AppSettings.shared
    @Loc private var trusted = AX.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings.enabled }, set: { settings.enabled = $0; if $0 { settings.pausedUntil = nil } })) {
                    Text("Check my writing everywhere")
                    Text("Turn off to stop Inkwell in every app. You can also do this from the menu bar.")
                }
                Toggle("Open Inkwell when I log in", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
            Section("Shortcut") {
                LabeledContent {
                    ShortcutRecorder(shortcut: $settings.hotkey)
                } label: {
                    Text("Improve selected text")
                    Text("Select text in any app and press this to open the chat panel. Click the shortcut to change it.")
                }
            }
            Section("Checking") {
                LabeledContent {
                    HStack {
                        Slider(value: $settings.checkDelay, in: 0.3...2.0, step: 0.1).frame(width: 180)
                        Text(String(format: "%.1fs", settings.checkDelay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 36)
                    }
                } label: {
                    Text("Wait before checking")
                    Text("How long after you stop typing. Shorter feels faster, longer uses less AI.")
                }
            }
            Section("Permission") {
                LabeledContent {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings") { AX.requestTrust(); AX.openAccessibilitySettings() }
                    }
                } label: {
                    Text("Accessibility access")
                    Text("Lets Inkwell see the text field you're typing in and apply fixes. Password fields are always skipped.")
                }
                if !trusted { PermissionHelp().frame(maxWidth: .infinity, alignment: .leading) }
            }
            Section("About") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Source and releases") {
                    Link("github.com/jaiedsabid/Inkwell", destination: URL(string: "https://github.com/jaiedsabid/Inkwell")!)
                }
            }
        }
        .onReceive(poll) { _ in trusted = AX.isTrusted }
    }
}

extension GeneralPane {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}

// MARK: - Writing

struct WritingPane: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var nav = SettingsNav.shared

    var body: some View {
        Form {
            Section("Language") {
                LanguagePicker(code: $settings.languageCode)
                Toggle(isOn: $settings.autoDetectLanguage) {
                    Text("Detect language automatically")
                    Text("If you write in another language, Inkwell checks it in that language.")
                }
            }
            Section {
                ToneGrid(selection: $settings.tone, columns: 4, onAdd: { nav.editingTone = CustomTone(name: "", guidance: "") })
                    .padding(.vertical, 4)
                Text(settings.tone.guidance).font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Default tone")
            } footer: {
                Text("You can pick a different tone for each app in Apps & Websites.")
            }
            Section {
                if settings.customTones.isEmpty {
                    Text("Make a tone that sounds like you, like “Warm but brief” or “Playful, with British spelling”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(settings.customTones) { t in
                    HStack(spacing: 10) {
                        Image(systemName: t.symbol).foregroundStyle(Theme.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name)
                            Text(t.guidance).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button { nav.editingTone = t } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("Edit")
                        Button { settings.customTones.removeAll { $0.id == t.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete")
                    }
                }
                Button { nav.editingTone = CustomTone(name: "", guidance: "") } label: { Label("New tone", systemImage: "plus") }
            } header: {
                Text("Your tones")
            }
            Section("Suggestions") {
                Picker("How strict", selection: $settings.strictness) {
                    ForEach(Strictness.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.strictness.detail).font(.callout).foregroundStyle(.secondary)
                Toggle(isOn: $settings.showExplanations) {
                    Text("Explain each fix")
                    Text("A short line saying why, so you learn as you go.")
                }
                Toggle(isOn: $settings.toneCheck) {
                    Text("Check tone")
                    Text("A purple line when a sentence sounds off for your tone, like too blunt or too casual.")
                }
            }
            Section {
                Toggle(isOn: $settings.autocomplete) {
                    Text("Suggest what comes next")
                    Text("Gray text after the cursor when you pause. Tab accepts it, → takes one word, Esc hides it.")
                }
                if settings.autocomplete {
                    Picker("Length", selection: $settings.completionLength) {
                        ForEach(CompletionLength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Next-word suggestions")
            } footer: {
                Text("Uses your live-checking model. Works at the end of a line, in any app where Inkwell is on.")
            }
            Section {
                ForEach(IssueKind.allCases.filter { $0 != .tone }) { kind in
                    Toggle(isOn: Binding(get: { !settings.disabledKinds.contains(kind) },
                                         set: { if $0 { settings.disabledKinds.remove(kind) } else { settings.disabledKinds.insert(kind) } })) {
                        Label {
                            Text(kind.label)
                            Text(kind.detail)
                        } icon: {
                            Image(systemName: kind.symbol).foregroundStyle(Color(nsColor: kind.color))
                        }
                    }
                }
            } header: {
                Text("What to check")
            } footer: {
                Text("Tone is under Suggestions above.")
            }
            Section("What the colors mean") {
                ColorRow(color: Theme.red, style: "Wavy", title: "Mistake", detail: "Spelling, grammar, punctuation or capitals. Hover to see the fix and its type.")
                ColorRow(color: Theme.blue, style: "Line", title: "Clearer sentence", detail: "The whole sentence could read better.")
                if settings.toneCheck {
                    ColorRow(color: Theme.purple, style: "Dashed", title: "Tone", detail: "The sentence doesn't match the tone you picked.")
                }
            }
        }
    }
}

struct ColorRow: View {
    var color: NSColor
    var style: String
    var title: String
    var detail: String
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: color)).frame(width: 26, height: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - AI

struct AIPane: View {
    @ObservedObject var settings = AppSettings.shared
    @Loc private var keyDraft = ""
    @Loc private var hasKey = false
    @Loc private var testState: TestState = .idle
    @Loc private var models: [String] = []
    @Loc private var loadingModels = false

    enum TestState: Equatable { case idle, running, ok, failed(String) }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(EngineKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.engine == .cloud
                     ? (settings.provider.isLocal ? "Uses models running in Ollama on this Mac. Nothing leaves your computer."
                                                  : "Best quality. Your text is sent to the provider you choose, using your own API key.")
                     : settings.engine == .local
                     ? "Download a free model from Hugging Face and run it on this Mac. Private and works offline."
                     : "Uses Apple's built-in model (macOS 26 with Apple Intelligence). Nothing to download.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if settings.engine == .cloud {
                Section {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(Provider.allCases) { Text($0.label).tag($0) }
                    }
                    Text(settings.provider.blurb).font(.callout).foregroundStyle(.secondary)
                    if settings.provider.needsKey {
                        LabeledContent("API key") {
                            HStack {
                                SecureField(hasKey ? "Saved in Keychain" : settings.provider.keyPrefixHint, text: $keyDraft)
                                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 240)
                                Button("Save") { save() }.disabled(keyDraft.isEmpty)
                                if hasKey { Button("Remove") { Keychain.set(nil, for: settings.provider); refreshKey() } }
                            }
                        }
                    } else {
                        LabeledContent("Ollama address") {
                            HStack {
                                TextField("", text: $settings.ollamaURL, prompt: Text("http://localhost:11434"))
                                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
                                    .onSubmit { loadModels() }
                                Button("Connect") { loadModels() }
                            }
                        }
                        if !loadingModels && models.isEmpty {
                            HStack {
                                Label("Ollama isn't running, or has no models yet.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).font(.callout)
                                Spacer()
                                Link("Get Ollama", destination: URL(string: "https://ollama.com/download")!)
                            }
                            Text("Install Ollama, then in Terminal run for example  ollama pull gemma3  and click Connect.")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    LabeledContent("Connection") {
                        HStack {
                            switch testState {
                            case .idle: EmptyView()
                            case .running: ProgressView().controlSize(.small)
                            case .ok: Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed(let msg): Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                            Button("Test") { test() }.disabled((settings.provider.needsKey && !hasKey) || testState == .running)
                        }
                    }
                } header: {
                    Text("Provider")
                }
                Section {
                    ModelField(title: "Live checking", detail: "Runs often: pick a fast, low-cost model.",
                               value: Binding(get: { settings.checkModel }, set: { settings.checkModel = $0 }), options: models, loading: loadingModels)
                    ModelField(title: "Chat and rewrites", detail: "Pick a stronger model.",
                               value: Binding(get: { settings.chatModel }, set: { settings.chatModel = $0 }), options: models, loading: loadingModels)
                    HStack {
                        if !settings.provider.defaultCheckModel.isEmpty {
                            Button("Use recommended models") {
                                settings.checkModel = settings.provider.defaultCheckModel
                                settings.chatModel = settings.provider.defaultChatModel
                            }
                        }
                        Spacer()
                        Button { loadModels() } label: { Label("Refresh list", systemImage: "arrow.clockwise") }
                            .disabled(loadingModels || (settings.provider.needsKey && !hasKey && settings.provider != .openrouter))
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text(models.isEmpty ? "Type a model name, or add your key to choose from the provider's list."
                                        : "\(models.count) models available from \(settings.provider.label).")
                }
            } else if settings.engine == .local {
                LocalModelsSection()
            } else {
                Section("Status") {
                    if let why = OnDevice.unavailableReason {
                        Label("Not available: \(why).", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text("Spelling always works offline. The on-device model handles grammar, rewrites and chat, with somewhat lower quality than cloud models.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { refreshKey(); loadModels() }
        .onChange(of: settings.provider) { _, _ in refreshKey(); testState = .idle; models = []; loadModels() }
    }

    private func refreshKey() { hasKey = Keychain.get(settings.provider) != nil; keyDraft = "" }

    private func save() {
        Keychain.set(keyDraft, for: settings.provider)
        refreshKey()
        test()
        loadModels()
        Coordinator.shared.checker.invalidate()
    }

    private func loadModels() {
        guard settings.engine == .cloud else { return }
        let provider = settings.provider
        let key = Keychain.get(provider)
        if provider.needsKey && key == nil && provider != .openrouter { models = []; return }
        loadingModels = true
        Task {
            let list = await ModelLister.fetch(provider, key: key, ollamaURL: settings.ollamaURL)
            guard provider == settings.provider else { return }
            models = list
            loadingModels = false
            // Ollama has no defaults: start with the first installed model.
            if provider == .ollama, let first = list.first {
                if settings.checkModel.isEmpty { settings.checkModel = first }
                if settings.chatModel.isEmpty { settings.chatModel = first }
            }
        }
    }

    private func test() {
        testState = .running
        Task {
            do {
                let client = try AI.client()
                _ = try await client.complete(system: "Reply with the word OK.", messages: [.init(role: .user, text: "Ping")], jsonSchema: nil, purpose: .check)
                testState = .ok
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Apps & Websites

struct AppsPane: View {
    @ObservedObject var settings = AppSettings.shared
    @Loc private var newSite = ""

    private struct AppEntry: Identifiable { let id: String; let name: String; let icon: NSImage? }

    /// Running apps plus any app that has a setting, sorted by name.
    private var apps: [AppEntry] {
        var seen = Set<String>()
        var out: [AppEntry] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            out.append(AppEntry(id: id, name: app.localizedName ?? id, icon: app.icon))
        }
        for id in Set(settings.appTones.keys).union(settings.disabledApps) where !seen.contains(id) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            seen.insert(id)
            out.append(AppEntry(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                                icon: NSWorkspace.shared.icon(forFile: url.path)))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                ForEach(apps) { app in
                    HStack(spacing: 10) {
                        if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                        Text(app.name)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.appTones[app.id] },
                            set: { settings.appTones[app.id] = $0 })) {
                            Text("Default tone").tag(Tone?.none)
                            Divider()
                            ForEach(Tone.allCases) { Text($0.label).tag(Tone?.some($0)) }
                        }
                        .labelsHidden().fixedSize()
                        .disabled(settings.disabledApps.contains(app.id))
                        Toggle("Check in \(app.name)", isOn: Binding(
                            get: { !settings.disabledApps.contains(app.id) },
                            set: { if $0 { settings.disabledApps.remove(app.id) } else { settings.disabledApps.insert(app.id) } }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Switch an app off to stop checking there. Password managers and terminals start off. Open apps are listed; others appear once you change them.")
            }

            Section {
                ForEach(settings.disabledSites.sorted(), id: \.self) { site in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(site)
                        Spacer()
                        Button { settings.disabledSites.remove(site) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Check this site again")
                    }
                }
                HStack {
                    TextField("Add a website, like docs.google.com", text: $newSite).textFieldStyle(.roundedBorder).labelsHidden()
                        .onSubmit(addSite)
                    Button("Add", action: addSite).disabled(newSite.isEmpty)
                }
            } header: {
                Text("Websites where Inkwell stays off")
            } footer: {
                Text("Works in Safari, Chrome, Edge, Brave, Arc and other browsers. Subdomains are included.")
            }
        }
    }

    private func addSite() {
        var s = newSite.trimmingCharacters(in: .whitespaces).lowercased()
        if let host = URL(string: s.contains("://") ? s : "https://" + s)?.host { s = host }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        guard !s.isEmpty else { return }
        settings.disabledSites.insert(s)
        newSite = ""
    }
}

// MARK: - Dictionary & Privacy

struct PrivacyPane: View {
    @ObservedObject var settings = AppSettings.shared
    @Loc private var newWord = ""
    @Loc private var filter = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add a word, name or term", text: $newWord).textFieldStyle(.roundedBorder).labelsHidden()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if settings.dictionary.count > 8 {
                    TextField("Search", text: $filter).textFieldStyle(.roundedBorder).labelsHidden()
                }
                if settings.dictionary.isEmpty {
                    Text("No words yet. Add names, product terms or slang you use, or choose “Add to dictionary” on a suggestion.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(settings.dictionary.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }.sorted(), id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button { remove(word) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Personal dictionary (\(settings.dictionary.count))")
            } footer: {
                Text("Words here are never marked as mistakes.")
            }

            Section {
                if settings.ignoredSuggestions.isEmpty {
                    Text("None. Choose “Always ignore this suggestion” in a suggestion's ••• menu to stop seeing it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(settings.ignoredSuggestions, id: \.self) { key in
                    HStack {
                        Text(key.replacingOccurrences(of: "→", with: "  →  ")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { settings.ignoredSuggestions.removeAll { $0 == key } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Show this suggestion again")
                    }
                }
            } header: {
                Text("Ignored suggestions (\(settings.ignoredSuggestions.count))")
            }

            Section("Privacy") {
                PrivacyRow(symbol: "lock.fill", title: "Password fields are never read", detail: "Secure fields are skipped in every app.")
                PrivacyRow(symbol: "hand.raised.fill", title: "Off in password managers and terminals", detail: "Change this in Apps & Websites.")
                PrivacyRow(symbol: "internaldrive", title: "Spelling is checked on your Mac",
                           detail: settings.engine != .cloud || settings.provider.isLocal
                               ? "Grammar and rewrites also run on your Mac. Nothing is sent anywhere."
                               : "For grammar and rewrites, only the sentences being checked are sent to \(settings.provider.label), using your key. Inkwell has no servers and keeps no copy.")
                PrivacyRow(symbol: "key.fill", title: "Your API key stays in the Keychain", detail: "It's only sent to your provider.")
            }
        }
    }

    private func add() {
        settings.addToDictionary(newWord)
        newWord = ""
    }

    private func remove(_ word: String) {
        settings.dictionary.removeAll { $0 == word }
        NSSpellChecker.shared.unlearnWord(word)
    }
}

struct PrivacyRow: View {
    var symbol: String
    var title: String
    var detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.green).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Quick prompts

struct PromptsPane: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach($settings.savedPrompts) { $p in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "bookmark.fill").foregroundStyle(.pink)
                            TextField("", text: $p.title, prompt: Text("Name")).textFieldStyle(.plain).labelsHidden().fontWeight(.semibold)
                            Spacer()
                            Button { settings.savedPrompts.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).help("Delete")
                        }
                        TextField("", text: $p.instruction, prompt: Text("What should Inkwell do?"), axis: .vertical)
                            .textFieldStyle(.plain).labelsHidden().foregroundStyle(.secondary).lineLimit(1...4)
                    }
                    .padding(.vertical, 4)
                }
                .onMove { settings.savedPrompts.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    settings.savedPrompts.append(SavedPrompt(title: "New prompt", instruction: ""))
                } label: { Label("Add prompt", systemImage: "plus") }
            } header: {
                Text("Your prompts")
            } footer: {
                Text("These appear as buttons in the chat panel, next to Shorter, Friendlier and the others. You can also right-click anything you typed in the chat and choose “Save as a quick prompt”.")
            }
        }
    }
}

// MARK: - Tone editor

struct ToneEditor: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Loc private var draft: CustomTone
    @Loc private var preview: String?
    @Loc private var previewing = false

    private let isNew: Bool
    private let sample = "hey, the meeting got moved to 3pm tomorrow. can you still make it? let me know asap"
    private let ideas = ["Warm but brief", "Playful and witty", "Calm and reassuring", "Direct, no small talk",
                         "Polite, with British spelling", "Enthusiastic, like a good teacher"]

    init(draft: CustomTone) {
        _draft = Loc(wrappedValue: draft)
        isNew = !AppSettings.shared.customTones.contains { $0.id == draft.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New tone" : "Edit tone").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.callout.weight(.medium))
                TextField("", text: $draft.name, prompt: Text("Like “Founder”, “Gentle” or “Pirate”"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How should it sound?").font(.callout.weight(.medium))
                TextField("", text: $draft.guidance, prompt: Text("Describe it in plain words, like “Friendly and short. Use simple words. No exclamation marks.”"), axis: .vertical)
                    .textFieldStyle(.roundedBorder).labelsHidden().lineLimit(3...6)
                HStack(spacing: 6) {
                    ForEach(ideas.prefix(3), id: \.self) { idea in ideaChip(idea) }
                }
                HStack(spacing: 6) {
                    ForEach(ideas.suffix(3), id: \.self) { idea in ideaChip(idea) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.callout.weight(.medium))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                    ForEach(CustomTone.symbols, id: \.self) { sym in
                        Button { draft.symbol = sym } label: {
                            Image(systemName: sym)
                                .frame(width: 30, height: 30)
                                .foregroundStyle(draft.symbol == sym ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                .background(draft.symbol == sym ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Try it").font(.callout.weight(.medium))
                    Spacer()
                    if previewing { ProgressView().controlSize(.small) }
                    Button("Rewrite sample") { runPreview() }.disabled(!canSave || previewing).controlSize(.small)
                }
                Text(sample).font(.callout).foregroundStyle(.secondary)
                if let preview {
                    Text(preview).font(.callout).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        settings.customTones.removeAll { $0.id == draft.id }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add tone" : "Save") { save() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    private func ideaChip(_ idea: String) -> some View {
        Button(idea) {
            draft.guidance = idea + "."
            if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { draft.name = idea.components(separatedBy: CharacterSet(charactersIn: ",")).first ?? idea }
        }
        .buttonStyle(.plain).font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.guidance = draft.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = settings.customTones.firstIndex(where: { $0.id == draft.id }) {
            settings.customTones[i] = draft
        } else {
            settings.customTones.append(draft)
            settings.tone = Tone(id: draft.id)   // a new tone is usually wanted right away
        }
        dismiss()
    }

    private func runPreview() {
        previewing = true
        preview = nil
        let guidance = draft.guidance.isEmpty ? "Sound \(draft.name.lowercased())." : draft.guidance
        Task {
            do {
                let client = try AI.client()
                let system = """
                You rewrite text in a requested tone. Reply with only the rewritten text.
                Tone: \(draft.name). \(guidance)
                """
                let out = try await client.complete(system: system, messages: [.init(role: .user, text: sample)], jsonSchema: nil, purpose: .chat)
                preview = ChatPrompt.clean(out)
            } catch {
                preview = error.localizedDescription
            }
            previewing = false
        }
    }
}

/// A model name: typed in, or picked from the provider's list (searchable when long).
struct ModelField: View {
    var title: String
    var detail: String
    @Binding var value: String
    var options: [String]
    var loading: Bool
    @Loc private var showList = false
    @Loc private var search = ""

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("", text: $value, prompt: Text("model name")).textFieldStyle(.roundedBorder).labelsHidden().frame(width: 230)
                if loading {
                    ProgressView().controlSize(.small)
                } else if !options.isEmpty {
                    Button { search = ""; showList = true } label: { Image(systemName: "chevron.up.chevron.down") }
                        .help("Choose from the list")
                        .popover(isPresented: $showList, arrowEdge: .bottom) { list }
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if options.count > 12 {
                TextField("", text: $search, prompt: Text("Search models")).textFieldStyle(.roundedBorder).labelsHidden().padding(8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(options.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { m in
                        Button {
                            value = m
                            showList = false
                        } label: {
                            HStack {
                                Text(m).lineLimit(1)
                                Spacer()
                                if m == value { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 320)
    }
}

/// Click, then press the keys you want. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @StateObject private var rec = ShortcutRecording()
    @ObservedObject private var hotkey = Hotkey.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if shortcut != .default && !rec.recording {
                    Button { rec.set(.default, into: $shortcut) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Use the default, \(Shortcut.default.label)")
                }
                Button { rec.recording ? rec.stop() : rec.start(into: $shortcut) } label: {
                    HStack(spacing: 6) {
                        if rec.recording {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        }
                        Text(rec.recording ? "Type a shortcut…" : shortcut.label)
                            .font(.system(size: 12, weight: rec.recording ? .regular : .medium)).monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .frame(minWidth: 120)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(rec.recording ? Theme.accent.opacity(0.12) : Color(nsColor: .controlColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(rec.recording ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: rec.recording ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(rec.recording ? "Press Esc to cancel" : "Click to change")
            }
            if let error = rec.error { Text(error).font(.caption).foregroundStyle(.red) }
            else if hotkey.taken && !rec.recording {
                Text("Another app uses this shortcut. Click it to choose a different one.").font(.caption).foregroundStyle(.orange)
            } else if let other = hotkey.likelyClash(for: shortcut), !rec.recording {
                Text("\(other) may also use this shortcut.").font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { rec.stop() }
    }
}

@MainActor
final class ShortcutRecording: ObservableObject {
    @Published var recording = false
    @Published var error: String?
    private var monitor: Any?

    func start(into binding: Binding<Shortcut>) {
        error = nil
        recording = true
        Hotkey.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil }          // Esc
            guard let s = Shortcut(event: event) else {
                self.error = "Use at least one of ⌘, ⌥ or ⌃."
                return nil
            }
            self.set(s, into: binding)
            self.stop()
            return nil
        }
    }

    func stop() {
        guard recording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        Hotkey.shared.resume()
    }

    func set(_ s: Shortcut, into binding: Binding<Shortcut>) {
        let old = binding.wrappedValue
        guard Hotkey.shared.register(s) else {
            error = "\(s.label) is used by another app. Try a different one."
            Hotkey.shared.register(old)
            return
        }
        error = nil
        binding.wrappedValue = s
    }
}
