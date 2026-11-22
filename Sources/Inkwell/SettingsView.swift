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
                Picker(selection: $settings.hotkey) {
                    ForEach(HotkeyPreset.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Improve selected text")
                    Text("Select text in any app and press this to open the chat panel.")
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
        }
        .onReceive(poll) { _ in trusted = AX.isTrusted }
    }
}

// MARK: - Writing

struct WritingPane: View {
    @ObservedObject var settings = AppSettings.shared

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
                ToneGrid(selection: $settings.tone, columns: 4).padding(.vertical, 4)
                Text(settings.tone.guidance).font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Default tone")
            } footer: {
                Text("You can pick a different tone for each app in Apps & Websites.")
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
            Section("What the colors mean") {
                ColorRow(color: Theme.red, style: "Wavy", title: "Mistake", detail: "Spelling or grammar. Hover to see the fix.")
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

    enum TestState: Equatable { case idle, running, ok, failed(String) }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(EngineKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.engine == .cloud
                     ? "Best quality. Your text is sent to the provider you choose, using your own API key."
                     : "Runs on this Mac with Apple's on-device model. Nothing leaves your computer.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if settings.engine == .cloud {
                Section("Provider") {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(Provider.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("API key") {
                        HStack {
                            SecureField(hasKey ? "Saved in Keychain" : settings.provider.keyPrefixHint, text: $keyDraft)
                                .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 240)
                            Button("Save") { save() }.disabled(keyDraft.isEmpty)
                            if hasKey { Button("Remove") { Keychain.set(nil, for: settings.provider); refreshKey() } }
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
                            Button("Test") { test() }.disabled(!hasKey || testState == .running)
                        }
                    }
                }
                Section {
                    TextField("Live checking", text: $settings.checkModel)
                    TextField("Chat and rewrites", text: $settings.chatModel)
                    Button("Use recommended models") {
                        settings.checkModel = settings.provider.defaultCheckModel
                        settings.chatModel = settings.provider.defaultChatModel
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Live checking runs often, so a fast, low-cost model works best. Rewrites use a stronger model.")
                }
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
        .onAppear(perform: refreshKey)
        .onChange(of: settings.provider) { _, _ in refreshKey(); testState = .idle }
    }

    private func refreshKey() { hasKey = Keychain.get(settings.provider) != nil; keyDraft = "" }

    private func save() {
        Keychain.set(keyDraft, for: settings.provider)
        refreshKey()
        test()
        Coordinator.shared.checker.invalidate()
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
                        Toggle("", isOn: Binding(
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

            Section("Privacy") {
                PrivacyRow(symbol: "lock.fill", title: "Password fields are never read", detail: "Secure fields are skipped in every app.")
                PrivacyRow(symbol: "hand.raised.fill", title: "Off in password managers and terminals", detail: "Change this in Apps & Websites.")
                PrivacyRow(symbol: "internaldrive", title: "Spelling is checked on your Mac",
                           detail: settings.engine == .onDevice
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
