import AppKit
import ApplicationServices
import Combine

/// Watches the text field the user is typing in (in any app), keeps the checker fed, draws the underlines and shows
/// the suggestion card on hover.
@MainActor
final class Coordinator: ObservableObject {
    static let shared = Coordinator()

    enum FieldState: Equatable { case off, needsPermission, idle, watching(app: String) }

    let checker = Checker()
    let overlay = OverlayController()
    let card = SuggestionCardController()

    @Published private(set) var state: FieldState = .idle
    @Published private(set) var frontApp: NSRunningApplication?

    private(set) var element: AXUIElement?
    private var lastValue: String?
    private var timer: Timer?
    private var tickCount = 0
    private var hoverWork: DispatchWorkItem?
    private var hoverCandidate: String?
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    func start() {
        card.configure(actions: CardActions(accept: { [weak self] in self?.accept($0) },
                                            dismiss: { [weak self] in self?.dismiss($0) }))
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, AX.isTrusted { AX.prepare(app: app) }
                self?.card.hide()
            }
        }
        checker.$issues.sink { [weak self] issues in
            DispatchQueue.main.async { self?.card.refresh(with: issues); self?.layout() }
        }.store(in: &bag)
        // Re-check everything when the tone or language changes.
        settings.$tone.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.checker.invalidate() } }.store(in: &bag)
        settings.$languageCode.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.checker.invalidate() } }.store(in: &bag)
        installMouseMonitors()
    }

    private func installMouseMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved(NSEvent.mouseLocation) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { handler($0); return $0 }) { monitors.append(l) }
        if let k = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.card.hide() }
        }) { monitors.append(k) }
    }

    // MARK: Focus tracking

    private func tick() {
        tickCount += 1
        guard settings.isActive else { return stop(.off) }
        guard AX.isTrusted else { return stop(.needsPermission) }
        if monitors.count < 3 { installMouseMonitors() }

        guard let front = NSWorkspace.shared.frontmostApplication else { return stop(.idle) }
        // Our own panels (chat, settings) keep the last field as it was.
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        frontApp = front
        AX.prepare(app: front)

        guard let el = AX.focusedElement(), AX.pid(el) == front.processIdentifier,
              !AX.isSecure(el), AX.isEditableText(el) else { return stop(.idle) }

        if element == nil || !CFEqual(element!, el) {
            element = el
            lastValue = nil
            checker.reset()
            card.hide()
        }
        state = .watching(app: front.localizedName ?? "this app")

        let value = AX.value(el) ?? ""
        if value != lastValue {
            lastValue = value
            checker.textChanged(value, cursor: AX.selectedRange(el)?.location)
        }
        // Positions move when the field scrolls or the window moves, so re-measure regularly.
        if checker.issues.count <= 30 || tickCount % 4 == 0 { layout() }
    }

    private func stop(_ s: FieldState) {
        if state != s { state = s }
        if element != nil {
            element = nil
            lastValue = nil
            checker.reset()
        }
        overlay.clear()
        card.hide()
    }

    /// Re-checks the current field now (after settings change or a replacement).
    func refreshNow() {
        lastValue = nil
        tick()
    }

    // MARK: Layout

    private func layout() {
        guard let el = element else { overlay.clear(); return }
        let issues = checker.issues
        guard !issues.isEmpty else { overlay.clear(); return }
        let fieldFrame = AX.frame(el)
        var segments: [Segment] = []
        for issue in issues {
            for r in rects(el, issue.range) {
                var rect = r
                if let f = fieldFrame {
                    // Hide marks scrolled out of the field.
                    let clip = f.insetBy(dx: -2, dy: -2)
                    guard clip.intersects(rect) else { continue }
                    rect = rect.intersection(clip)
                }
                guard rect.width >= 2 else { continue }
                segments.append(Segment(rect: rect.flippedToCocoa, kind: issue.kind, issueID: issue.id))
            }
        }
        var badge: (rect: CGRect, count: Int)?
        if segments.isEmpty, let f = fieldFrame {
            // The app didn't tell us where the words are: show a count badge at the field's bottom-right corner.
            let size: CGFloat = 20
            let r = CGRect(x: f.maxX - size - 6, y: f.maxY - size - 6, width: size, height: size).flippedToCocoa
            badge = (r, issues.count)
        }
        overlay.update(segments: segments, badge: badge)
    }

    /// One rect per line the range covers (top-left screen coordinates).
    private func rects(_ el: AXUIElement, _ range: NSRange) -> [CGRect] {
        guard range.length > 0, let full = AX.bounds(el, range) else { return [] }
        let lineHeight = AX.bounds(el, NSRange(location: range.location, length: 1))?.height ?? full.height
        if full.height < max(lineHeight, 8) * 1.6 { return [full] }

        var out: [CGRect] = []
        if let l1 = AX.line(el, forIndex: range.location), let l2 = AX.line(el, forIndex: NSMaxRange(range) - 1),
           l2 >= l1, l2 - l1 < 40 {
            for line in l1...l2 {
                guard let lr = AX.range(el, forLine: line) else { continue }
                let inter = NSIntersectionRange(lr, range)
                if inter.length > 0, let b = AX.bounds(el, inter) { out.append(b) }
            }
            if !out.isEmpty { return out }
        }
        // No line info: measure word by word and join words on the same line.
        guard let text = lastValue else { return [] }
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return [] }
        var count = 0
        ns.enumerateSubstrings(in: range, options: .byWords) { _, wr, _, stop in
            count += 1
            if count > 80 { stop.pointee = true; return }
            guard let b = AX.bounds(el, wr) else { return }
            if let last = out.last, abs(last.midY - b.midY) < lineHeight / 2 {
                out[out.count - 1] = last.union(b)
            } else {
                out.append(b)
            }
        }
        return out
    }

    // MARK: Hover

    private func mouseMoved(_ p: CGPoint) {
        if card.contains(p) { card.cancelHide(); return }
        if let seg = overlay.hit(p) {
            overlay.hoveredID = seg.issueID
            if card.currentID == seg.issueID { card.cancelHide(); return }
            guard hoverCandidate != seg.issueID else { return }
            hoverCandidate = seg.issueID
            hoverWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.showCard(for: seg.issueID) }
            hoverWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
            return
        }
        if overlay.badgeHit(p), let b = overlay.badge {
            if !card.isVisible { card.show(checker.issues, anchor: b.rect) }
            card.cancelHide()
            return
        }
        hoverCandidate = nil
        hoverWork?.cancel()
        overlay.hoveredID = nil
        card.scheduleHide()
    }

    private func showCard(for id: String) {
        let issues = checker.issues
        guard let idx = issues.firstIndex(where: { $0.id == id }) else { return }
        let anchor = overlay.segments.filter { $0.issueID == id }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        guard !anchor.isNull else { return }
        card.show([issues[idx]], anchor: anchor)
    }

    // MARK: Actions

    func accept(_ issue: Issue) {
        guard let el = element else { return }
        card.hide()
        let anchor = card.anchor
        Task {
            let outcome = await Replacer.replace(in: el, range: issue.range, expected: issue.original, with: issue.replacement)
            if outcome == .failed {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.replacement, forType: .string)
                Toast.shared.show("Couldn't edit this field. Suggestion copied, paste with ⌘V.", near: anchor)
            }
            refreshNow()
        }
    }

    func dismiss(_ issue: Issue) {
        checker.dismiss(issue)
        card.hide()
    }
}
