import SwiftUI

/// Tone chips used in the menu, settings and onboarding.
struct ToneGrid: View {
    @Binding var selection: Tone
    var columns = 4

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
struct MenuContent: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var coordinator = Coordinator.shared
    @ObservedObject var checker = Coordinator.shared.checker
    @ObservedObject var stats = Stats.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            notices
            if settings.enabled, let app = coordinator.frontApp, app.bundleIdentifier != nil {
                VStack(spacing: 6) {
                    ToggleRow(title: "Check in \(app.localizedName ?? "this app")", icon: app.icon,
                              isOn: !settings.disabledApps.contains(app.bundleIdentifier!)) { coordinator.setChecking($0, app: true) }
                    if let host = coordinator.host {
                        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                        ToggleRow(title: "Check on \(site)", symbol: "globe",
                                  isOn: !settings.isDisabled(app: nil, host: host)) { coordinator.setChecking($0, app: false) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Tone").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ToneGrid(selection: $settings.tone)
            }
            HStack {
                Text("Language").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                LanguagePicker(code: $settings.languageCode).labelsHidden().fixedSize()
            }
            if settings.collectStats {
                let today = stats.summary(.day).total
                Button { closeMenu(); AppDelegate.shared?.showSettings(.stats) } label: {
                    HStack(spacing: 14) {
                        MiniStat(value: today.words, label: "words today")
                        MiniStat(value: today.fixedTotal, label: "fixes")
                        MiniStat(value: today.rewrites, label: "rewrites")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            VStack(spacing: 2) {
                MenuRow(title: "Improve selected text", symbol: "sparkles", shortcut: settings.hotkey.label) {
                    closeMenu(); ChatController.shared.open()
                }
                MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") {
                    closeMenu(); AppDelegate.shared?.showSettings()
                }
                MenuRow(title: "Quit Inkwell", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 310)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(settings.isActive ? Theme.accent : Color.gray.opacity(0.5))
                Image(systemName: settings.isActive ? "pencil.line" : "pencil.slash").foregroundStyle(.white).font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Inkwell").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { settings.enabled }, set: { settings.enabled = $0; if $0 { settings.pausedUntil = nil } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help(settings.enabled ? "Turn Inkwell off everywhere" : "Turn Inkwell on")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if coordinator.state == .needsPermission {
            Notice(symbol: "lock.shield", color: .orange, text: "Inkwell needs Accessibility access to read what you type.", button: "Allow") {
                closeMenu(); AppDelegate.shared?.showOnboarding()
            }
        } else if settings.enabled && !AI.isConfigured {
            Notice(symbol: "key", color: .orange, text: "Spelling works now. Add an AI key for grammar and rewrites.", button: "Set up") {
                closeMenu(); AppDelegate.shared?.showSettings(.ai)
            }
        }
        if settings.isPaused, let until = settings.pausedUntil {
            Notice(symbol: "pause.circle", color: .secondary, text: "Paused until \(until.formatted(date: .omitted, time: .shortened))", button: "Resume") {
                settings.resume()
            }
        } else if settings.enabled {
            HStack {
                Menu {
                    Button("For 30 minutes") { settings.pause(for: 1800) }
                    Button("For 1 hour") { settings.pause(for: 3600) }
                    Button("Until tomorrow") { settings.pauseUntilTomorrow() }
                } label: { Label("Pause", systemImage: "pause.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
        }
    }

    private var statusText: String {
        if !settings.enabled { return "Off everywhere" }
        if settings.isPaused { return "Paused" }
        switch coordinator.state {
        case .needsPermission: return "Needs permission"
        case .off: return "Off"
        case .idle: return "On · type in any app"
        case .disabled(let where_): return "Off in \(where_)"
        case .watching(let app):
            switch checker.status {
            case .checking: return "Checking in \(app)…"
            case .error: return "Checking in \(app) · AI unavailable"
            default:
                let n = checker.issues.count
                return n == 0 ? "Looks good in \(app)" : "\(n) suggestion\(n == 1 ? "" : "s") in \(app)"
            }
        }
    }

    private func closeMenu() {
        NSApp.keyWindow?.close()
    }
}

struct MenuRow: View {
    var title: String
    var symbol: String
    var shortcut: String?
    var action: () -> Void
    @Loc private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Notice: View {
    var symbol: String
    var color: Color
    var text: String
    var button: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small)
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct ToggleRow: View {
    var title: String
    var icon: NSImage? = nil
    var symbol: String? = nil
    var isOn: Bool
    var set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
            else if let symbol { Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary) }
            Text(title).lineLimit(1)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: set)).toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
    }
}

struct MiniStat: View {
    var value: Int
    var label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
