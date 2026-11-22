import AppKit

/// One drawn underline: the text it sits under (Cocoa screen coordinates) and which issue it belongs to.
struct Segment: Equatable {
    var rect: CGRect
    var kind: IssueKind
    var issueID: String
}

/// Click-through, transparent windows (one per screen) that draw the underlines on top of other apps.
@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private(set) var segments: [Segment] = []
    private(set) var badge: (rect: CGRect, count: Int)?
    var hoveredID: String? { didSet { if hoveredID != oldValue { redraw() } } }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
        rebuildWindows()
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0) }
        redraw()
    }

    func update(segments: [Segment], badge: (rect: CGRect, count: Int)?) {
        let badgeSame = self.badge?.rect == badge?.rect && self.badge?.count == badge?.count
        guard segments != self.segments || !badgeSame else {
            // Same marks: just make sure their window is still on screen.
            if !segments.isEmpty || badge != nil {
                for w in windows where !w.isVisible && segments.contains(where: { $0.rect.intersects(w.frame) }) { w.orderFrontRegardless() }
            }
            return
        }
        self.segments = segments
        self.badge = badge
        redraw()
    }

    func clear() { update(segments: [], badge: nil) }

    private func redraw() {
        for w in windows {
            let local = segments.filter { $0.rect.intersects(w.frame) }
            let b = badge.flatMap { $0.rect.intersects(w.frame) ? $0 : nil }
            w.canvas.set(segments: local, badge: b, hovered: hoveredID, origin: w.frame.origin)
            // Draw right now, before the window is shown or hidden. Otherwise macOS shows the window's last picture
            // (the previous underline, in its old place) for a moment when it comes back.
            w.canvas.display()
            if local.isEmpty && b == nil { w.orderOut(nil) } else if !w.isVisible { w.orderFrontRegardless() }
            Log.write("overlay \(w.windowNumber): \(local.count) underlines, visible \(w.isVisible)", key: "overlay\(w.windowNumber)")
        }
    }

    /// The issue under the mouse, if any.
    func hit(_ p: CGPoint) -> Segment? {
        segments.first { $0.rect.insetBy(dx: -1, dy: -3).contains(p) }
    }

    func badgeHit(_ p: CGPoint) -> Bool { badge?.rect.insetBy(dx: -4, dy: -4).contains(p) ?? false }
}

final class OverlayWindow: NSWindow {
    let canvas = OverlayCanvas()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        canvas.frame = CGRect(origin: .zero, size: screen.frame.size)
        canvas.autoresizingMask = [.width, .height]
        contentView = canvas
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayCanvas: NSView {
    private var segments: [Segment] = []
    private var badge: (rect: CGRect, count: Int)?
    private var hovered: String?
    private var origin: CGPoint = .zero

    override var isFlipped: Bool { false }

    func set(segments: [Segment], badge: (rect: CGRect, count: Int)?, hovered: String?, origin: CGPoint) {
        self.segments = segments
        self.badge = badge
        self.hovered = hovered
        self.origin = origin
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for s in segments {
            let r = s.rect.offsetBy(dx: -origin.x, dy: -origin.y)
            let color = s.kind.color
            if s.issueID == hovered {
                color.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
            }
            let y = r.minY + 1
            let path = NSBezierPath()
            path.lineCapStyle = .round
            switch s.kind {
            case .spelling, .grammar, .punctuation, .capitalization:
                // soft wavy line
                path.lineWidth = 1.6
                let wave: CGFloat = 1.6, step: CGFloat = 3
                var x = r.minX
                path.move(to: CGPoint(x: x, y: y))
                var up = true
                while x < r.maxX {
                    let nx = min(x + step, r.maxX)
                    path.curve(to: CGPoint(x: nx, y: y), controlPoint1: CGPoint(x: x + step / 2, y: y + (up ? wave : -wave)),
                               controlPoint2: CGPoint(x: x + step / 2, y: y + (up ? wave : -wave)))
                    x = nx
                    up.toggle()
                }
                color.setStroke()
            case .clarity:
                path.lineWidth = 2
                path.move(to: CGPoint(x: r.minX, y: y))
                path.line(to: CGPoint(x: r.maxX, y: y))
                color.withAlphaComponent(0.85).setStroke()
            case .tone:
                path.lineWidth = 2
                path.setLineDash([4, 3], count: 2, phase: 0)
                path.move(to: CGPoint(x: r.minX, y: y))
                path.line(to: CGPoint(x: r.maxX, y: y))
                color.withAlphaComponent(0.9).setStroke()
            }
            path.stroke()
        }
        if let b = badge {
            // Fallback when the app can't tell us where words are: a count pill at the field's corner.
            let r = b.rect.offsetBy(dx: -origin.x, dy: -origin.y)
            let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            Theme.red.setFill()
            pill.fill()
            let text = "\(b.count)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }
}
