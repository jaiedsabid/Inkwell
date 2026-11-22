import AppKit
import Combine
import SwiftUI

/// The menu bar icon and its panel. Replaces SwiftUI's MenuBarExtra, whose window keeps a stale height (leaving a gap
/// at the top and a shaded strip at the bottom) when the content changes size.
@MainActor
final class StatusMenu: NSObject {
    static let shared = StatusMenu()

    private var item: NSStatusItem?
    private let panel = MenuPanel()
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
        updateIcon()
        let s = AppSettings.shared
        Publishers.Merge(s.$enabled.map { _ in () }, s.$pausedUntil.map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &bag)

        let host = NSHostingView(rootView: MenuRoot { [weak self] size in self?.resize(to: size) })
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func updateIcon() {
        let active = AppSettings.shared.isActive
        let img = NSImage(systemSymbolName: active ? "pencil.line" : "pencil.slash", accessibilityDescription: "Inkwell")
        img?.isTemplate = true
        item?.button?.image = img
        item?.button?.appearsDisabled = !active
    }

    var isOpen: Bool { panel.isVisible }

    @objc private func toggle() { isOpen ? close() : open() }

    func open() {
        guard let button = item?.button, let bw = button.window else { return }
        let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size == .zero ? CGSize(width: 320, height: 400) : panel.frame.size
        let screen = bw.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        // Under the icon, right edges aligned when possible, kept on screen.
        var x = b.maxX - size.width + 8
        x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        panel.setFrame(CGRect(x: x, y: b.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        // Key (for Esc and menus) without activating Inkwell, so the app you were typing in keeps focus.
        panel.makeKeyAndOrderFront(nil)
        item?.button?.highlight(true)
        installMonitors()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item?.button?.highlight(false)
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    /// Keeps the top edge under the menu bar; the panel grows or shrinks downward with its content.
    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var f = panel.frame
        if f.size == size { return }
        if f.size == .zero {
            panel.setContentSize(size)
            return
        }
        f.origin.y += f.height - size.height
        f.size = size
        panel.setFrame(f, display: true)
    }

    private func installMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        // Clicks anywhere else close it.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(g) }
        // Esc closes it.
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53, self?.panel.isKeyWindow == true {
                MainActor.assumeIsolated { self?.close() }
                return nil
            }
            return e
        }) { monitors.append(l) }
    }
}

/// Borderless, transparent window: the SwiftUI content draws the rounded, translucent background.
final class MenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Menu content inside a rounded, translucent background, reporting its exact size so the panel fits it.
struct MenuRoot: View {
    var onSize: (CGSize) -> Void

    var body: some View {
        MenuContent()
            .fixedSize(horizontal: false, vertical: true)
            .background(VisualEffect(material: .menu))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { onSize($0) }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
