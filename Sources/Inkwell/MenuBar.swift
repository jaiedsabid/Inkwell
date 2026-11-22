import SwiftUI

/// Tone chips used in the menu, settings and onboarding.
struct ToneGrid: View {
    @Binding var selection: Tone
    var columns = 4
    /// Shows a "+ New" chip that calls this.
    var onAdd: (() -> Void)? = nil
    @ObservedObject private var settings = AppSettings.shared   // redraw when custom tones change

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(Tone.allCases) { tone in
                let on = tone == selection
                Button { selection = tone } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tone.symbol).font(.system(size: 13, weight: .medium))
                        Text(tone.label).font(.system(size: 10.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tone.guidance)
            }
            if let onAdd {
                Button(action: onAdd) {
                    VStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        Text("New tone").font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(.secondary)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Make your own tone")
            }
        }
    }
}

struct LanguagePicker: View {
    @Binding var code: String
    var body: some View {
        Picker("Language", selection: $code) {
            ForEach(WritingLanguage.all) { Text($0.name).tag($0.code) }
        }
    }
}

/// The popover under the menu bar icon.
/// The popover under the menu bar icon.
///
/// Layout, top to bottom: status + master switch, one setup notice at most, the app you're in (switch and tone),
/// writing defaults, today's numbers, the main action, and a quiet footer (pause, settings, quit).
struct MenuContent: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var coordinator = Coordinator.shared
    @ObservedObject var checker = Coordinator.shared.checker
    @ObservedObject var stats = Stats.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)

            if !settings.enabled {
                offState.padding(.horizontal, 14).padding(.bottom, 14)
            } else if settings.isPaused {
                pausedState.padding(.horizontal, 14).padding(.bottom, 14)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let notice { notice }
                    appCard
                    writingCard
                    if settings.collectStats { todayRow }
                    improveButton
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }

            Divider()
            footer.padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(settings.isActive ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Color.gray.opacity(0.35)))
                BrandGlyph(size: 20).foregroundStyle(.white.opacity(settings.isActive ? 1 : 0.8))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Inkwell").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { settings.enabled }, set: { settings.enabled = $0; if $0 { settings.pausedUntil = nil } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(settings.enabled ? "Turn Inkwell off everywhere" : "Turn Inkwell on")
        }
    }

    private var status: (text: String, color: Color) {
        if !settings.enabled { return ("Off everywhere", .gray) }
        if settings.isPaused, let until = settings.pausedUntil {
            return ("Paused until \(until.formatted(date: .omitted, time: .shortened))", .orange)
        }
        switch coordinator.state {
        case .needsPermission: return ("Needs permission", .orange)
        case .off: return ("Off", .gray)
        case .idle: return ("Ready · click into any text field", .green)
        case .disabled(let place): return ("Off in \(place)", .gray)
        case .watching(let app):
            switch checker.status {
            case .checking: return ("Checking in \(app)…", .green)
            case .error: return ("AI unavailable · spelling only", .orange)
            case .needsSetup: return ("Spelling only in \(app)", .orange)
            case .idle:
                let n = checker.issues.count
                return (n == 0 ? "All good in \(app)" : "\(n) suggestion\(n == 1 ? "" : "s") in \(app)", n == 0 ? .green : Color(nsColor: Theme.red))
            }
        }
    }

    // MARK: Off / paused

    private var offState: some View {
        VStack(spacing: 10) {
            Text("Inkwell isn't checking anything. Turn it on to get suggestions in every app.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn on") { settings.enabled = true; settings.pausedUntil = nil }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Card())
    }

    private var pausedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").font(.system(size: 26)).foregroundStyle(.orange)
            Text("Paused. Inkwell comes back on by itself, or you can resume now.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Resume now") { settings.resume() }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Card())
    }

    // MARK: Notice (at most one)

    private var notice: Notice? {
        if coordinator.state == .needsPermission {
            return Notice(symbol: "lock.shield.fill", color: .orange, text: "Allow Accessibility so Inkwell can read what you type.", button: "Allow") {
                closeMenu(); AppDelegate.shared?.showOnboarding()
            }
        }
        if !AI.isConfigured {
            return Notice(symbol: "sparkles", color: Theme.accent, text: setupText, button: "Set up") {
                closeMenu(); AppDelegate.shared?.showSettings(.ai)
            }
        }
        return nil
    }

    private var setupText: String {
        switch settings.engine {
        case .cloud: "Spelling works now. Add an AI key for grammar, rewrites and suggestions."
        case .local: "Spelling works now. Download a local model for grammar and rewrites."
        case .onDevice: "Apple's model isn't ready (\(OnDevice.unavailableReason ?? "unavailable")). Pick another AI."
        }
    }

    // MARK: This app

    @ViewBuilder
    private var appCard: some View {
        if let app = coordinator.frontApp, let id = app.bundleIdentifier {
            let on = !settings.disabledApps.contains(id)
            Caption("This app")
            VStack(spacing: 0) {
                Row {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(app.localizedName ?? "This app").fontWeight(.medium).lineLimit(1)
                } trailing: {
                    Toggle("", isOn: Binding(get: { on }, set: { coordinator.setChecking($0, app: true) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                        .help(on ? "Stop checking in this app" : "Check this app")
                }
                if on {
                    RowDivider()
                    Row {
                        Text("Tone here").foregroundStyle(.secondary)
                    } trailing: {
                        ToneMenu(selection: Binding(get: { settings.appTones[id] }, set: { settings.appTones[id] = $0 }),
                                 defaultLabel: "Default (\(settings.tone.label))")
                    }
                    if let host = coordinator.host {
                        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                        let siteOn = !settings.isDisabled(app: nil, host: host)
                        RowDivider()
                        Row {
                            Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 18)
                            Text(site).lineLimit(1).truncationMode(.middle)
                        } trailing: {
                            Toggle("", isOn: Binding(get: { siteOn }, set: { coordinator.setChecking($0, app: false) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                        }
                    }
                }
            }
            .background(Card())
        }
    }

    // MARK: Writing

    @ViewBuilder
    private var writingCard: some View {
        Caption("Writing")
        VStack(spacing: 0) {
            Row {
                Text("Default tone").foregroundStyle(.secondary)
            } trailing: {
                ToneMenu(selection: Binding(get: { settings.tone }, set: { settings.tone = $0 ?? .natural }), defaultLabel: nil)
            }
            RowDivider()
            Row {
                Text("Language").foregroundStyle(.secondary)
            } trailing: {
                Menu {
                    ForEach(WritingLanguage.all) { lang in
                        Button { settings.languageCode = lang.code } label: {
                            if lang.code == settings.languageCode { Label(lang.name, systemImage: "checkmark") } else { Text(lang.name) }
                        }
                    }
                } label: {
                    MenuLabel(text: settings.language.name + (settings.autoDetectLanguage ? " · auto" : ""))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            RowDivider()
            Row {
                Text("Suggest next words").foregroundStyle(.secondary)
            } trailing: {
                Toggle("", isOn: $settings.autocomplete).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
        }
        .background(Card())
    }

    // MARK: Today

    private var todayRow: some View {
        let today = stats.summary(.day).total
        return Button { closeMenu(); AppDelegate.shared?.showSettings(.stats) } label: {
            HStack(spacing: 0) {
                Text("Today").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                StatChip(value: today.words, label: "words")
                StatChip(value: today.fixedTotal, label: "fixes")
                StatChip(value: today.rewrites, label: "rewrites")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See your writing stats")
    }

    // MARK: Main action

    private var improveButton: some View {
        Button { closeMenu(); ChatController.shared.open() } label: {
            HStack {
                Image(systemName: "sparkles")
                Text("Improve selected text")
                Spacer()
                Text(settings.hotkey.label).font(.system(size: 11, weight: .medium)).opacity(0.75)
            }
        }
        .buttonStyle(PrimaryButtonStyle(fullWidth: true))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            if settings.enabled && !settings.isPaused {
                Menu {
                    Button("For 30 minutes") { settings.pause(for: 1800) }
                    Button("For 1 hour") { settings.pause(for: 3600) }
                    Button("Until tomorrow") { settings.pauseUntilTomorrow() }
                } label: {
                    FooterLabel(symbol: "pause.circle", text: "Pause")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            Spacer()
            FooterButton(symbol: "gearshape", text: "Settings") { closeMenu(); AppDelegate.shared?.showSettings() }
            FooterButton(symbol: "power", text: "Quit") { NSApp.terminate(nil) }
        }
    }

    private func closeMenu() { StatusMenu.shared.close() }
}

// MARK: - Building blocks

/// Small uppercase label above a card.
private struct Caption: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold)).kerning(0.4)
            .foregroundStyle(.tertiary)
            .padding(.leading, 4).padding(.bottom, -6)
    }
}

/// Rounded, subtly filled container for a group of rows.
private struct Card: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// One line in a card: content on the left, a control on the right.
private struct Row<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 12.5))
        .frame(minHeight: 34)
        .padding(.horizontal, 10)
    }
}

private struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 10) }
}

/// Text plus chevrons, for compact dropdowns.
struct MenuLabel: View {
    var text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Tone dropdown. With `defaultLabel`, offers "use the default" (nil) first.
struct ToneMenu: View {
    @Binding var selection: Tone?
    var defaultLabel: String?
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Menu {
            if let defaultLabel {
                Button { selection = nil } label: {
                    if selection == nil { Label(defaultLabel, systemImage: "checkmark") } else { Text(defaultLabel) }
                }
                Divider()
            }
            ForEach(Tone.allCases) { tone in
                Button { selection = tone } label: {
                    Label(tone.label, systemImage: tone == selection ? "checkmark" : tone.symbol)
                }
            }
            Divider()
            Button { StatusMenu.shared.close(); AppDelegate.shared?.showNewTone() } label: { Label("New tone…", systemImage: "plus") }
        } label: {
            if let t = selection { MenuLabel(text: t.label, symbol: t.symbol) } else { MenuLabel(text: defaultLabel ?? "Natural") }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct StatChip: View {
    var value: Int
    var label: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value.formatted()).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.trailing, 12)
    }
}

private struct FooterLabel: View {
    var symbol: String
    var text: String
    @Loc private var hover = false
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(hover ? .primary : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

private struct FooterButton: View {
    var symbol: String
    var text: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { FooterLabel(symbol: symbol, text: text) }
            .buttonStyle(.plain)
    }
}

struct Notice: View {
    var symbol: String
    var color: Color
    var text: String
    var button: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 14))
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).buttonStyle(SecondaryButtonStyle())
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
