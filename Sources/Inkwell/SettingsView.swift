import Combine
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, writing, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .writing: "Writing"
        case .ai: "AI Engine"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .writing: "textformat"
        case .ai: "cpu"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .writing: .blue
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
            }
            Section {
                ToneGrid(selection: $settings.tone, columns: 4).padding(.vertical, 4)
                Text(settings.tone.guidance).font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Default tone")
            }
            Section("What the colors mean") {
                ColorRow(color: Theme.red, style: "Wavy", title: "Mistake", detail: "Spelling or grammar. Hover to see the fix.")
                ColorRow(color: Theme.blue, style: "Line", title: "Clearer sentence", detail: "The whole sentence could read better.")
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
