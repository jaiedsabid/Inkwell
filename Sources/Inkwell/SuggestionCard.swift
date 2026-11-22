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
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }

    /// Hosts a SwiftUI view, sized to fit it.
    func host<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: view)
        contentView = hosting
        setContentSize(hosting.fittingSize)
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
                    Circle().fill(Color(nsColor: issue.kind.color)).frame(width: 8, height: 8)
                    Text(issue.kind.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if model.issues.count > 1 {
                        Button { model.index = (model.index - 1 + model.issues.count) % model.issues.count } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        Text("\(model.index + 1) of \(model.issues.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button { model.index = (model.index + 1) % model.issues.count } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }

                if issue.kind.isSentenceLevel {
                    Text(issue.replacement)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(issue.original).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(issue.replacement).fontWeight(.semibold)
                    }
                    .font(.body)
                }

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

                    Button("Dismiss") { actions.dismiss(issue) }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    if model.fixAllCount > 1, !issue.kind.isSentenceLevel {
                        Button("Fix all \(model.fixAllCount)") { actions.fixAll() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    Menu {
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
        .frame(width: 320, alignment: .leading)
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

    func configure(actions: CardActions) {
        panel.host(SuggestionCardView(model: model, actions: actions))
    }

    func show(_ issues: [Issue], start: Int = 0, anchor: CGRect) {
        cancelHide()
        model.issues = issues
        model.index = min(start, max(issues.count - 1, 0))
        self.anchor = anchor
        if let v = panel.contentView { panel.setContentSize(v.fittingSize) }
        panel.place(near: anchor)
        if !panel.isVisible { panel.alphaValue = 0; panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func hide() {
        cancelHide()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.issues = []
    }

    func scheduleHide(after delay: TimeInterval = 0.35) {
        guard hideWork == nil, panel.isVisible else { return }
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
            if let v = panel.contentView { panel.setContentSize(v.fittingSize) }
        }
    }

    func contains(_ p: CGPoint) -> Bool { panel.isVisible && panel.frame.insetBy(dx: -10, dy: -10).contains(p) }
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
            Image(systemName: "pencil.line").foregroundStyle(Theme.accent)
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
