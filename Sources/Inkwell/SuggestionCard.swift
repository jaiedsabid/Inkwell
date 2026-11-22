import AppKit
import SwiftUI

/// A borderless panel that floats over other apps without taking focus from them.
final class FloatingPanel: NSPanel {
    private let allowKey: Bool

    init(allowKey: Bool = false) {
        self.allowKey = allowKey
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .none   // the card fades in by itself; no system zoom
    }

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }

    private var hosting: NSView?

    /// Hosts a SwiftUI view, sized to fit it.
    func host<V: View>(_ view: V) {
        let h = NSHostingView(rootView: view)
        hosting = h
        contentView = h
        fit()
    }

    /// Resizes the panel to its SwiftUI content. Call after the content changes; keeps the top edge in place.
    func fit(keepTop: Bool = true) {
        guard let h = hosting else { return }
        h.layoutSubtreeIfNeeded()
        let size = h.fittingSize
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        var f = frame
        if keepTop { f.origin.y += f.height - size.height }
        f.size = size
        setFrame(f, display: true)
    }

    /// Places the panel under `anchor` (Cocoa screen coordinates), or above it if there's no room below.
    func place(near anchor: CGRect, gap: CGFloat = 8) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        var x = anchor.minX
        var y = anchor.minY - gap - size.height
        if y < vis.minY { y = anchor.maxY + gap }
        x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        y = min(max(y, vis.minY + 8), vis.maxY - size.height - 8)
        setFrameOrigin(CGPoint(x: x, y: y))
    }
}

// MARK: - Suggestion card

@MainActor
final class CardModel: ObservableObject {
    @Published var issues: [Issue] = []
    @Published var index = 0
    /// Word-level fixes in the whole field, for "Fix all".
    @Published var fixAllCount = 0
    @Published var appName: String?
    @Published var host: String?
    var current: Issue? { issues.indices.contains(index) ? issues[index] : nil }
}

struct CardActions {
    var accept: (Issue) -> Void
    var dismiss: (Issue) -> Void
    var ignoreAlways: (Issue) -> Void = { _ in }
    var stopKind: (IssueKind) -> Void = { _ in }
    var fixAll: () -> Void = {}
    var addWord: (String) -> Void = { _ in }
    var disableApp: () -> Void = {}
    var disableSite: () -> Void = {}
}

struct SuggestionCardView: View {
    @ObservedObject var model: CardModel
    @ObservedObject var settings = AppSettings.shared
    let actions: CardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue = model.current {
                HStack(spacing: 6) {
                    // What kind of suggestion this is
                    Label(issue.kind.label, systemImage: issue.kind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: issue.kind.color))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(nsColor: issue.kind.color).opacity(0.13), in: Capsule())
                    Spacer()
                    if model.issues.count > 1 {
                        Button { model.index = (model.index - 1 + model.issues.count) % model.issues.count } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        Text("\(model.index + 1) of \(model.issues.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button { model.index = (model.index + 1) % model.issues.count } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }

                // The change, shown where it happens: removed words struck through, new words highlighted.
                Text(SuggestionText.make(issue))
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if settings.showExplanations, !issue.explanation.isEmpty {
                    Text(issue.explanation)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button { actions.accept(issue) } label: {
                        Label("Accept", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button("Ignore") { actions.dismiss(issue) }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Ignore this suggestion here")
                    Spacer()
                    if model.fixAllCount > 1, !issue.kind.isSentenceLevel {
                        Button("Fix all \(model.fixAllCount)") { actions.fixAll() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .lineLimit(1).fixedSize()
                    }
                    Menu {
                        Button("Always ignore this suggestion") { actions.ignoreAlways(issue) }
                        Button("Stop checking \(issue.kind.label.lowercased())") { actions.stopKind(issue.kind) }
                        Divider()
                        if issue.kind == .spelling {
                            Button("Add “\(issue.original)” to dictionary") { actions.addWord(issue.original) }
                        }
                        if let app = model.appName { Button("Turn off in \(app)") { actions.disableApp() } }
                        if let host = model.host { Button("Turn off on \(host)") { actions.disableSite() } }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
        .padding(14)
        .frame(width: (model.current?.kind.isSentenceLevel ?? false) ? 360 : 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

@MainActor
final class SuggestionCardController {
    private let panel = FloatingPanel()
    let model = CardModel()
    private(set) var anchor: CGRect = .zero
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }
    var currentID: String? { isVisible ? model.current?.id : nil }

    /// True while the card's ••• menu is open. The menu draws outside the card, so moving onto its items must not
    /// count as leaving the card.
    private(set) var menuOpen = false
    private var menuObservers: [Any] = []

    func configure(actions: CardActions) {
        panel.host(SuggestionCardView(model: model, actions: actions))
        let nc = NotificationCenter.default
        menuObservers = [
            nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.panel.isVisible else { return }
                    self.menuOpen = true
                    self.cancelHide()
                }
            },
            nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.menuOpen else { return }
                    self.menuOpen = false
                    // Closed without picking anything while the pointer is elsewhere: hide as usual.
                    if !self.contains(NSEvent.mouseLocation) { self.scheduleHide(after: 0.6) }
                }
            },
        ]
    }

    func show(_ issues: [Issue], start: Int = 0, anchor: CGRect) {
        cancelHide()
        model.issues = issues
        model.index = min(start, max(issues.count - 1, 0))
        self.anchor = anchor
        panel.fit(keepTop: false)
        panel.place(near: anchor)
        if !panel.isVisible { panel.alphaValue = 0; panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        // SwiftUI finishes laying out the new issue on the next pass: measure again then.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.fit(keepTop: false)
            self.panel.place(near: anchor)
        }
    }

    func hide() {
        cancelHide()
        menuOpen = false
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.issues = []
    }

    func scheduleHide(after delay: TimeInterval = 0.35) {
        guard hideWork == nil, panel.isVisible, !menuOpen else { return }
        let w = DispatchWorkItem { [weak self] in self?.hideWork = nil; self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func cancelHide() { hideWork?.cancel(); hideWork = nil }

    /// Keeps the card in sync when the issue list changes under it.
    func refresh(with all: [Issue]) {
        guard panel.isVisible else { return }
        let ids = Set(all.map(\.id))
        let kept = model.issues.filter { ids.contains($0.id) }
        if kept.isEmpty { hide(); return }
        if kept.count != model.issues.count {
            model.issues = kept
            model.index = min(model.index, kept.count - 1)
            DispatchQueue.main.async { [weak self] in self?.panel.fit() }
        }
    }

    func contains(_ p: CGPoint) -> Bool { panel.isVisible && (menuOpen || panel.frame.insetBy(dx: -10, dy: -10).contains(p)) }
}

// MARK: - Toast

@MainActor
final class Toast {
    static let shared = Toast()
    private let panel = FloatingPanel()
    private var work: DispatchWorkItem?

    func show(_ message: String, near anchor: CGRect? = nil, action: (title: String, run: () -> Void)? = nil, duration: TimeInterval = 2.5) {
        work?.cancel()
        let view = HStack(spacing: 10) {
            BrandGlyph(size: 15).foregroundStyle(Theme.accent)
            Text(message).font(.callout)
            if let action {
                Button(action.title) { action.run(); self.hide() }
                    .buttonStyle(.borderless).fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        panel.host(view)
        if let anchor { panel.place(near: anchor) } else if let s = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: s.visibleFrame.midX - panel.frame.width / 2, y: s.visibleFrame.minY + 80))
        }
        panel.orderFrontRegardless()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: w)
    }

    func hide() { work?.cancel(); panel.orderOut(nil) }
}

/// Builds the styled text for a suggestion card.
enum SuggestionText {
    static func make(_ issue: Issue) -> AttributedString {
        var out = AttributedString()
        func add(_ s: String, _ style: Style) {
            guard !s.isEmpty else { return }
            var a = AttributedString(s)
            switch style {
            case .context:
                a.foregroundColor = .secondary
            case .kept:
                a.foregroundColor = .primary
            case .removed:
                a.foregroundColor = Color(nsColor: Theme.red).opacity(0.85)
                a.strikethroughStyle = .single
            case .added:
                a.foregroundColor = Theme.accent
                a.font = .system(size: 13.5, weight: .semibold)
                a.backgroundColor = Theme.accent.opacity(0.16)
            case .plain:
                a.foregroundColor = .primary
            }
            out += a
        }

        // Whole-sentence rewrites; a short wordy phrase ("in order to" → "to") reads better in context below.
        if issue.kind.isSentenceLevel, WordDiff.words(issue.original).count > 6 {
            let segs = WordDiff.segments(from: issue.original, to: issue.replacement)
            let kept = segs.filter { $0.kind == .same }.reduce(0) { $0 + WordDiff.words($1.text).count }
            // Mostly rewritten: a word-by-word diff would be noise, so just show the new sentence.
            if Double(kept) < Double(max(WordDiff.words(issue.original).count, 1)) * 0.5 {
                add(issue.replacement, .plain)
                return out
            }
            for seg in segs {
                if !out.characters.isEmpty { add(" ", .kept) }
                add(seg.text, seg.kind == .same ? .kept : seg.kind == .removed ? .removed : .added)
            }
            return out
        }

        add(issue.before, .context)
        let o = issue.original, r = issue.replacement
        if r.hasPrefix(o) {                       // something added after: "soon" → "soon."
            add(o, .kept); add(String(r.dropFirst(o.count)), .added)
        } else if r.hasSuffix(o) {                // something added before
            add(String(r.dropLast(o.count)), .added); add(o, .kept)
        } else {
            add(o, .removed); add(" ", .kept); add(r, .added)
        }
        add(issue.after, .context)
        return out
    }

    enum Style { case context, kept, removed, added, plain }
}
