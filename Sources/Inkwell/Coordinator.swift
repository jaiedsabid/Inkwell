import AppKit
import ApplicationServices
import Combine

/// Watches the text field the user is typing in (in any app), keeps the checker fed, draws the underlines and shows
/// the suggestion card on hover.
@MainActor
final class Coordinator: ObservableObject {
    static let shared = Coordinator()

    enum FieldState: Equatable { case off, needsPermission, idle, watching(app: String), disabled(app: String) }

    let checker = Checker()
    let overlay = OverlayController()
    let card = SuggestionCardController()

    @Published private(set) var state: FieldState = .idle
    @Published private(set) var frontApp: NSRunningApplication?

    private(set) var element: AXUIElement?
    /// Website the field is on (browsers only).
    @Published private(set) var host: String?
    private var lastValue: String?
    private var lastWordCount = 0
    private var seenIssues = Set<String>()
    private var timer: Timer?
    private var tickCount = 0
    /// Whether the focused field is a search/address box, worked out once per field.
    private var searchCache: (element: AXUIElement, result: Bool)?
    /// Underlines already drawn, by content (so they follow their word as text shifts).
    private var shownKeys = Set<String>()
    /// First measurement of underlines not drawn yet; drawn once a second measurement agrees.
    private var pendingRects: [String: [CGRect]] = [:]
    private var confirmScheduled = false
    private var wasTrusted = false
    private var hoverWork: DispatchWorkItem?
    private var hoverCandidate: String?
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    /// Snapshots only: pretend an app is in front.
    func previewFrontApp(_ app: NSRunningApplication?, host: String? = nil) { frontApp = app; self.host = host }

    func start() {
        Autocomplete.shared.overlay = overlay
        card.configure(actions: CardActions(
            accept: { [weak self] in self?.accept($0) },
            dismiss: { [weak self] in self?.dismiss($0) },
            ignoreAlways: { [weak self] issue in
                let s = AppSettings.shared
                if !s.ignoredSuggestions.contains(issue.dismissKey) { s.ignoredSuggestions.append(issue.dismissKey) }
                Stats.shared.dismissed()
                self?.card.hide()
            },
            stopKind: { [weak self] kind in
                AppSettings.shared.disabledKinds.insert(kind)
                self?.card.hide()
                Toast.shared.show("\(kind.label) checks are off. Turn them back on in Settings → Writing.", duration: 4)
            },
            fixAll: { [weak self] in self?.fixAll() },
            addWord: { [weak self] word in
                AppSettings.shared.addToDictionary(word)
                self?.card.hide()
            },
            disableApp: { [weak self] in self?.setChecking(false, app: true) },
            disableSite: { [weak self] in self?.setChecking(false, app: false) }))
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, AX.isTrusted { AX.prepare(app: app) }
                // Opening the card's own menu can bring Inkwell forward; that isn't leaving the card.
                if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.card.hide() }
            }
        }
        checker.$issues.sink { [weak self] issues in
            DispatchQueue.main.async {
                guard let self else { return }
                self.card.refresh(with: issues)
                self.layout()
                for i in issues where self.seenIssues.insert(i.dismissKey).inserted { Stats.shared.found(i.kind) }
            }
        }.store(in: &bag)
        // Re-check everything when the tone or language changes.
        settings.$tone.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.checker.invalidate() } }.store(in: &bag)
        settings.$languageCode.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.checker.invalidate() } }.store(in: &bag)
        Publishers.Merge5(settings.$strictness.dropFirst().map { _ in () }, settings.$appTones.dropFirst().map { _ in () },
                          settings.$dictionary.dropFirst().map { _ in () }, settings.$autoDetectLanguage.dropFirst().map { _ in () },
                          settings.$toneCheck.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.checker.invalidate() } }.store(in: &bag)
        Publishers.Merge(settings.$ignoredSuggestions.dropFirst().map { _ in () }, settings.$disabledKinds.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.checker.recompute() } }.store(in: &bag)
        settings.$customTones.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.checker.invalidate() } }.store(in: &bag)
        Publishers.Merge(settings.$disabledApps.dropFirst().map { _ in () }, settings.$disabledSites.dropFirst().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.refreshNow() } }.store(in: &bag)
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
            MainActor.assumeIsolated { if self?.card.menuOpen == false { self?.card.hide() } }
        }) { monitors.append(k) }
    }

    // MARK: Focus tracking

    private func tick() {
        tickCount += 1
        guard settings.isActive else { overlay.hideWindows(); return stop(.off) }
        guard AX.isTrusted else { wasTrusted = false; return stop(.needsPermission) }
        if !wasTrusted {
            // Permission just arrived: event monitors made before it don't receive events, so make them again.
            wasTrusted = true
            installMouseMonitors()
            Autocomplete.shared.installKeyTap()
        }

        guard let front = NSWorkspace.shared.frontmostApplication else { return stop(.idle) }
        // Our own panels (chat, settings) keep the last field as it was.
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        frontApp = front
        AX.prepare(app: front)

        let app = front.bundleIdentifier ?? "?"
        guard let el = AX.focusedElement() else { Log.write("\(app): no focused element"); return stop(.idle) }
        let role = AX.role(el)
        guard !AX.isSecure(el) else { Log.write("\(app): secure field skipped"); return stop(.idle) }
        let searchLike: Bool
        if let c = searchCache, CFEqual(c.element, el) { searchLike = c.result } else {
            searchLike = AX.isSearchLike(el)
            searchCache = (el, searchLike)
        }
        guard !searchLike else { Log.write("\(app): search or address field skipped"); return stop(.idle) }
        guard AX.isEditableText(el) else {
            Log.write("\(app): focused \(role)/\(AX.subrole(el)) is not editable text (pid \(AX.pid(el) ?? -1) vs \(front.processIdentifier))")
            return stop(.idle)
        }

        let appName = front.localizedName ?? "this app"
        if element == nil || !CFEqual(element!, el) {
            element = el
            lastValue = nil
            host = AX.pageURL(el)?.host
            checker.reset()
            checker.appBundleID = front.bundleIdentifier
            seenIssues = []
            shownKeys = []
            pendingRects = [:]
            lastWordCount = -1
            card.hide()
        } else if tickCount % 8 == 0 {
            host = AX.pageURL(el)?.host
        }
        if settings.isDisabled(app: front.bundleIdentifier, host: host) {
            stopChecking()
            if state != .disabled(app: host ?? appName) { state = .disabled(app: host ?? appName) }
            return
        }
        state = .watching(app: appName)

        let value = AX.value(el) ?? ""
        Log.write("\(app): watching \(role), \(checker.issues.count) issues, ai \(checker.status)")
        if value != lastValue {
            lastValue = value
            // Count words the user writes (not text that was already there or pasted in bulk).
            let words = Stats.wordCount(value)
            if lastWordCount >= 0, case let added = words - lastWordCount, added > 0, added < 40 {
                Stats.shared.wordsWritten(added, app: front.localizedName)
            }
            lastWordCount = words
            checker.textChanged(value, cursor: AX.selectedRange(el)?.location)
        }
        Autocomplete.shared.update(element: el, value: value, selection: AX.selectedRange(el))
        // Positions move when the field scrolls or the window moves, so re-measure regularly.
        if checker.issues.count <= 30 || tickCount % 4 == 0 { layout() }
    }

    private func stop(_ s: FieldState) {
        if state != s { state = s }
        if element != nil {
            element = nil
            host = nil
        }
        stopChecking()
    }

    private func stopChecking() {
        Autocomplete.shared.dismiss(reset: true)
        if lastValue != nil { lastValue = nil; checker.reset() }
        overlay.clear()
        card.hide()
    }

    /// Turns checking on or off for the current app (or, with `app: false`, the current website).
    func setChecking(_ on: Bool, app: Bool) {
        card.hide()
        if app {
            guard let id = frontApp?.bundleIdentifier else { return }
            if on { settings.disabledApps.remove(id) } else { settings.disabledApps.insert(id) }
        } else {
            guard let h = host?.lowercased() else { return }
            let site = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            if on { settings.disabledSites.remove(site); settings.disabledSites.remove(h) } else { settings.disabledSites.insert(site) }
        }
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
        var anyMeasured = false
        var needsConfirm = false
        var keys = Set<String>()
        var ordinal: [String: Int] = [:]
        for issue in issues {
            var rects: [CGRect] = []
            for r in self.rects(el, issue.range) {
                var rect = r
                if let f = fieldFrame {
                    // Hide marks scrolled out of the field.
                    let clip = f.insetBy(dx: -2, dy: -2)
                    guard clip.intersects(rect) else { continue }
                    rect = rect.intersection(clip)
                }
                guard rect.width >= 2 else { continue }
                rects.append(rect.flippedToCocoa)
            }
            guard !rects.isEmpty else { continue }
            anyMeasured = true
            let base = "\(issue.kind.rawValue)|\(issue.original)|\(issue.replacement)"
            let key = "\(base)#\(ordinal[base, default: 0])"
            ordinal[base, default: 0] += 1
            keys.insert(key)
            // Apps can report a word's old position for a moment after the text changes. Draw a new underline only
            // when two measurements agree, so it doesn't appear in the wrong place and then jump.
            Log.write("measure \(issue.original): \(rects.map { "(\(Int($0.minX)),\(Int($0.minY)) w\(Int($0.width)))" }.joined())", key: "m-\(key)")
            let stable = shownKeys.contains(key) || pendingRects[key].map { Self.same($0, rects) } == true
            if stable {
                shownKeys.insert(key)
                pendingRects[key] = nil
                segments += rects.map { Segment(rect: $0, kind: issue.kind, issueID: issue.id) }
            } else {
                pendingRects[key] = rects
                needsConfirm = true
            }
        }
        shownKeys.formIntersection(keys)
        pendingRects = pendingRects.filter { keys.contains($0.key) }
        if needsConfirm && !confirmScheduled {
            confirmScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.confirmScheduled = false
                self?.layout()
            }
        }
        var badge: (rect: CGRect, count: Int)?
        if !anyMeasured, let f = fieldFrame {
            // The app didn't tell us where the words are: show a count badge at the field's bottom-right corner.
            let size: CGFloat = 20
            let r = CGRect(x: f.maxX - size - 6, y: f.maxY - size - 6, width: size, height: size).flippedToCocoa
            badge = (r, issues.count)
        }
        Log.write("layout: \(issues.count) issues → \(segments.count) underlines, badge \(badge != nil), field frame \(fieldFrame != nil)", key: "layout")
        overlay.update(segments: segments, badge: badge)
    }

    private static func same(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0.minX - $1.minX) < 1.5 && abs($0.minY - $1.minY) < 1.5 && abs($0.width - $1.width) < 1.5 }
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
            if !card.isVisible { prepareCard(); card.show(checker.issues, anchor: b.rect) }
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
        prepareCard()
        card.show([issues[idx]], anchor: anchor)
    }

    private func prepareCard() {
        card.model.fixAllCount = checker.issues.filter { !$0.kind.isSentenceLevel }.count
        card.model.appName = frontApp?.localizedName
        card.model.host = host
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
            } else {
                Stats.shared.fixed(issue)
                offerUndo([issue], in: el, near: anchor)
            }
            refreshNow()
        }
    }

    /// Applies every word-level fix in the field, last to first so earlier ranges stay valid.
    func fixAll() {
        guard let el = element else { return }
        card.hide()
        let anchor = card.anchor
        let fixes = checker.issues.filter { !$0.kind.isSentenceLevel }.sorted { $0.range.location > $1.range.location }
        Task {
            var applied: [Issue] = []
            for f in fixes where await Replacer.replace(in: el, range: f.range, expected: f.original, with: f.replacement) != .failed {
                applied.append(f)
                Stats.shared.fixed(f)
            }
            if !applied.isEmpty { offerUndo(applied, in: el, near: anchor) }
            refreshNow()
        }
    }

    /// Shows "Fixed · Undo". `applied` are the issues as they were before replacing.
    private func offerUndo(_ applied: [Issue], in el: AXUIElement, near anchor: CGRect) {
        // Where each replacement now sits: shift by the size change of fixes before it.
        var delta = 0
        var placed: [(range: NSRange, now: String, before: String)] = []
        for f in applied.sorted(by: { $0.range.location < $1.range.location }) {
            let len = (f.replacement as NSString).length
            placed.append((NSRange(location: f.range.location + delta, length: len), f.replacement, f.original))
            delta += len - f.range.length
        }
        let message = applied.count == 1 ? "Fixed" : "Fixed \(applied.count) mistakes"
        Toast.shared.show(message, near: anchor, action: ("Undo", { [weak self] in
            Task {
                for p in placed.reversed() {
                    _ = await Replacer.replace(in: el, range: p.range, expected: p.now, with: p.before)
                }
                self?.refreshNow()
            }
        }), duration: 5)
    }

    func dismiss(_ issue: Issue) {
        Stats.shared.dismissed()
        checker.dismiss(issue)
        card.hide()
    }
}
