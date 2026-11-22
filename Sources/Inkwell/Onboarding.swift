import Combine
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var hotkey = Hotkey.shared
    @Loc private var step = 0
    @Loc private var trusted = AX.isTrusted
    @Loc private var keyDraft = ""
    var finish: () -> Void
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permission
                case 2: writing
                case 3: engine
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40).padding(.top, 36)
            .transition(.opacity)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? Theme.accent : Color.secondary.opacity(0.25)).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 && step < steps - 1 { Button("Back") { withAnimation { step -= 1 } }.buttonStyle(.bordered) }
                primaryButton
            }
            .padding(20)
        }
        .frame(width: 600, height: 500)
        .onReceive(poll) { _ in trusted = AX.isTrusted }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case 1:
            if trusted { next("Continue") } else { Button("Skip for now") { withAnimation { step += 1 } }.buttonStyle(.bordered) }
        case 3:
            next(settings.engine == .cloud && keyDraft.isEmpty && Keychain.get(settings.provider) == nil ? "Skip for now" : "Continue") {
                if !keyDraft.isEmpty { Keychain.set(keyDraft, for: settings.provider) }
            }
        case steps - 1:
            Button("Start writing") { settings.onboarded = true; finish() }
                .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
        default: next(step == 0 ? "Get started" : "Continue")
        }
    }

    private func next(_ title: String, before: @escaping () -> Void = {}) -> some View {
        Button(title) { before(); withAnimation { step += 1 } }
            .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
    }

    private func hero(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            if symbol == "app" {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84).padding(-10)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 26) {
            hero("app", "Write better, everywhere", "Inkwell checks your writing in every app: browsers, Slack, Mail, Notes and more.")
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "scribble", color: Theme.red, title: "Fix mistakes as you type", detail: "Red lines mark mistakes. Hover to see the fix, click to apply.")
                Feature(symbol: "text.line.first.and.arrowtriangle.forward", color: Theme.blue, title: "Clearer sentences", detail: "Blue lines suggest a better way to say a whole sentence.")
                Feature(symbol: "sparkles", color: Theme.purple, title: "Ask for any change", detail: "Select text, press \(settings.hotkey.label), and say what you want.")
                Feature(symbol: "text.append", color: Theme.accentNS, title: "Finish your sentences", detail: "Gray suggestions appear as you type. Press Tab to accept.")
            }
            .frame(maxWidth: 420)
        }
    }

    private var permission: some View {
        VStack(spacing: 22) {
            hero("lock.shield", "Allow Inkwell to see what you type",
                 "macOS asks for Accessibility access. Inkwell uses it only to read the text field you're typing in and to apply fixes you accept.")
            VStack(alignment: .leading, spacing: 10) {
                Label("Password fields are never read", systemImage: "checkmark.shield")
                Label("You can turn Inkwell off for any app", systemImage: "checkmark.shield")
            }
            .foregroundStyle(.secondary)
            if trusted {
                Label("Access allowed", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            } else {
                VStack(spacing: 8) {
                    Button("Open System Settings") { AX.requestTrust(); AX.openAccessibilitySettings() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                    Text("Turn on Inkwell in the list, then come back here.").font(.caption).foregroundStyle(.secondary)
                    PermissionHelp()
                }
            }
        }
    }

    private var writing: some View {
        VStack(spacing: 22) {
            hero("textformat", "How do you write?", "You can change these any time from the menu bar.")
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Main language").fontWeight(.medium)
                    Spacer()
                    LanguagePicker(code: $settings.languageCode).labelsHidden().fixedSize()
                }
                Text("Default tone").fontWeight(.medium)
                ToneGrid(selection: $settings.tone)
                Text(settings.tone.guidance).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)
        }
    }

    private var engine: some View {
        VStack(spacing: 20) {
            hero("cpu", "Choose your AI", "Spelling works offline right away. Grammar, rewrites and chat need an AI.")
            HStack(spacing: 12) {
                EngineCard(selected: settings.engine == .cloud, symbol: "cloud", title: "Cloud AI", detail: "Best quality. Claude, GPT, Gemini, OpenRouter or Ollama.") { settings.engine = .cloud }
                EngineCard(selected: settings.engine == .local, symbol: "arrow.down.circle", title: "Local model",
                           detail: "Free and private. Download a model like Gemma 4 from Hugging Face.") { settings.engine = .local }
                EngineCard(selected: settings.engine == .onDevice, symbol: "apple.logo", title: "Apple",
                           detail: OnDevice.unavailableReason.map { "Not available: \($0)." } ?? "Private. Nothing leaves your Mac.") { settings.engine = .onDevice }
                    .disabled(!OnDevice.isSupportedOS)
            }
            .frame(maxWidth: 520)
            if settings.engine == .local {
                let rec = ModelStore.shared.model(MacInfo.recommendedID())
                VStack(alignment: .leading, spacing: 8) {
                    if let rec {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recommended for your Mac: \(rec.name)").fontWeight(.semibold)
                                Text("\(rec.sizeText) download. You can pick another model later in Settings.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            LocalDownloadButton(model: rec)
                        }
                    }
                }
                .frame(maxWidth: 520)
            }
            if settings.engine == .cloud {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(Provider.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    if settings.provider.needsKey {
                        SecureField("Paste your API key (\(settings.provider.keyPrefixHint))", text: $keyDraft).textFieldStyle(.roundedBorder)
                        Text("Stored in your Mac's Keychain. You pay your provider directly for what you use.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(settings.provider.blurb + " Pick a model in Settings → AI Engine after setup.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 460)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 24) {
            hero("checkmark", "You're all set", "Inkwell lives in your menu bar. Click into any text field and start typing.")
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "cursorarrow.rays", color: Theme.red, title: "Hover a line", detail: "See the fix and click Accept.")
                Feature(symbol: "keyboard", color: Theme.purple, title: "Press \(settings.hotkey.label)", detail: "With text selected, to rewrite it. With nothing selected, to write something new.")
                Feature(symbol: "text.append", color: Theme.accentNS, title: "Press Tab", detail: "To accept a gray suggestion. Esc hides it.")
                Feature(symbol: "menubar.arrow.up.rectangle", color: Theme.blue, title: "Menu bar icon", detail: "Turn Inkwell on or off, pause it, and change tone or language.")
            }
            .frame(maxWidth: 420)
            VStack(spacing: 10) {
                if hotkey.taken || hotkey.likelyClash(for: settings.hotkey) != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(hotkey.taken ? "\(settings.hotkey.label) is used by another app. Pick a different shortcut:"
                                          : "\(hotkey.likelyClash(for: settings.hotkey) ?? "Another app") may also use \(settings.hotkey.label). You can pick another:")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        ShortcutRecorder(shortcut: $settings.hotkey)
                    }
                }
                Toggle("Open Inkwell when I log in", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                    .toggleStyle(.checkbox)
            }
            .frame(maxWidth: 460)
            .onAppear {
                // A menu bar app should come back after a restart: on by default, shown here so it's easy to untick.
                let d = UserDefaults.standard
                if !d.bool(forKey: "offeredLoginItem") { d.set(true, forKey: "offeredLoginItem"); settings.launchAtLogin = true }
            }
        }
    }
}

struct Feature: View {
    var symbol: String
    var color: NSColor
    var title: String
    var detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(nsColor: color)).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct EngineCard: View {
    var selected: Bool
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.accent : .secondary)
                }
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(.quaternary.opacity(selected ? 0.9 : 0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown under "Open System Settings" while access is still missing.
struct PermissionHelp: View {
    @Loc private var open = false

    var body: some View {
        VStack(spacing: 8) {
            Button(open ? "Hide help" : "Already turned it on, but it still says no?") { withAnimation { open.toggle() } }
                .buttonStyle(.link).font(.caption)
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text("macOS can keep an old entry from an earlier copy of Inkwell, so the switch looks on but doesn't apply to this copy.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("1. Click Reset, then turn Inkwell on again in the list.\n2. Still no? Click Restart Inkwell.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Reset permission") { AX.resetPermission() }
                        Button("Restart Inkwell") { AX.relaunch() }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: 420, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// Download button with progress, used in onboarding.
struct LocalDownloadButton: View {
    let model: LocalModel
    @ObservedObject var store = ModelStore.shared

    var body: some View {
        if store.installed.contains(model.id) {
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let p = store.progress[model.id] {
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 110).tint(Theme.accent)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 34)
            }
        } else {
            Button("Download") { store.download(model) }.buttonStyle(.borderedProminent).tint(Theme.accent)
        }
    }
}
