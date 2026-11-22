import AppKit
import SwiftUI

/// `Inkwell --snapshot DIR`: renders the main screens to PNG files, for checking the UI without clicking around.
@MainActor
enum Snapshot {
    static func run(to dir: String) {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let card = CardModel()
        card.issues = [
            Issue(range: NSRange(location: 0, length: 3), kind: .grammar, original: "has", replacement: "have", explanation: "Use 'have' with 'I'."),
            Issue(range: NSRange(location: 4, length: 5), kind: .spelling, original: "recieve", replacement: "receive", explanation: ""),
        ]
        let sentence = CardModel()
        sentence.issues = [Issue(range: NSRange(location: 0, length: 40), kind: .clarity, original: "The thing that we did was to finish it.",
                                 replacement: "We finished it.", explanation: "Shorter and more direct.")]
        let chat = ChatModel()
        chat.source = "hey can u send me the report by tmrw, its kind of urgent because the client keep asking about it"
        chat.turns = [ChatModel.Turn(prompt: "make it professional", result: "Could you please send me the report by tomorrow? It's fairly urgent, as the client keeps asking about it."),
                      ChatModel.Turn(prompt: "shorter")]

        render(SuggestionCardView(model: card, actions: .init(accept: { _ in }, dismiss: { _ in })), "card-word", url)
        render(SuggestionCardView(model: sentence, actions: .init(accept: { _ in }, dismiss: { _ in })), "card-sentence", url)
        render(ChatView(model: chat, accept: {}, close: {}), "chat", url)
        render(ToneEditor(draft: CustomTone(name: "Warm but brief", guidance: "Warm but brief.", symbol: "heart")).background(Color(nsColor: .windowBackgroundColor)), "tone-editor", url)
        let punct = CardModel()
        punct.issues = [Issue(range: NSRange(location: 0, length: 4), kind: .punctuation, original: "soon", replacement: "soon.", explanation: "End the sentence with a full stop.")]
        render(SuggestionCardView(model: punct, actions: .init(accept: { _ in }, dismiss: { _ in })), "card-punctuation", url)

        // The real hover-card panel, opened the way hovering opens it.
        let ctl = SuggestionCardController()
        ctl.configure(actions: .init(accept: { _ in }, dismiss: { _ in }))
        ctl.model.fixAllCount = 3
        ctl.model.appName = "Notes"
        ctl.show([card.issues[0]], anchor: CGRect(x: 200, y: 600, width: 40, height: 14))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        print("card panel size: \(ctl.frame.size)")
        if let v = NSApp.windows.first(where: { $0.frame == ctl.frame })?.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("card-panel.png"))
        }
        ctl.hide()
        let st = AppSettings.shared
        let (savedEnabled, savedPause) = (st.enabled, st.pausedUntil)
        Coordinator.shared.previewFrontApp(NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first
                                           ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first, host: "docs.google.com")
        render(MenuContent().background(Color(nsColor: .windowBackgroundColor)), "menu", url)
        render(MenuContent().background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light), "menu-light", url)
        st.pausedUntil = Date().addingTimeInterval(3600)
        render(MenuContent().background(Color(nsColor: .windowBackgroundColor)), "menu-paused", url)
        st.pausedUntil = nil
        st.enabled = false
        render(MenuContent().background(Color(nsColor: .windowBackgroundColor)), "menu-off", url)
        st.enabled = savedEnabled
        st.pausedUntil = savedPause
        Coordinator.shared.previewFrontApp(nil)
        render(OnboardingView(finish: {}).background(Color(nsColor: .windowBackgroundColor)), "onboarding", url)
        var sample: [String: DayStats] = [:]
        for i in 0..<30 {
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            var d = DayStats()
            d.words = [820, 1240, 460, 0, 1580, 990, 1310][i % 7] + i * 7
            d.fixed = ["spelling": 6 + i % 4, "grammar": 4 + i % 3, "clarity": 2 + i % 2, "tone": i % 2]
            d.found = ["spelling": 9, "grammar": 7, "clarity": 5, "tone": 2]
            d.rewrites = i % 5
            d.mistakes = ["recieve → receive": 2, "its → it's": 1, "alot → a lot": i % 2]
            d.apps = ["Slack": d.words / 2, "Google Chrome": d.words / 3, "Mail": d.words / 6]
            sample[Stats.key(date)] = d
        }
        Stats.shared.preview(sample)
        let savedEngine = AppSettings.shared.engine
        SettingsNav.shared.pane = .ai
        AppSettings.shared.engine = .local
        render(SettingsView(), "settings-local", url)
        AppSettings.shared.engine = savedEngine
        for pane in SettingsPane.allCases {
            SettingsNav.shared.pane = pane
            render(SettingsView(), "settings-\(pane.rawValue)", url)
        }
        // Next-word suggestion as drawn over a text field
        for (name, bg, fg) in [("ghost-light", NSColor.white, NSColor.black), ("ghost-dark", NSColor(white: 0.12, alpha: 1), NSColor.white)] {
            let typed = "Thanks so much for your help with the" as NSString
            let font = NSFont.systemFont(ofSize: 14)
            let typedW = typed.size(withAttributes: [.font: font]).width
            let canvas = OverlayCanvas(frame: CGRect(x: 0, y: 0, width: 560, height: 44))
            canvas.set(segments: [], badge: nil, hovered: nil, origin: .zero)
            canvas.ghost = Ghost(text: " file organization project", rect: CGRect(x: 16 + typedW, y: 13, width: 560 - 22 - typedW, height: 18), fontSize: 14)
            let img = NSImage(size: canvas.bounds.size)
            img.lockFocus()
            bg.setFill(); canvas.bounds.fill()
            typed.draw(at: CGPoint(x: 16, y: 13 + (18 - typed.size(withAttributes: [.font: font]).height) / 2), withAttributes: [.font: font, .foregroundColor: fg])
            canvas.draw(canvas.bounds)
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("\(name).png"))
            }
        }
        print("Snapshots written to \(dir)")
    }

    private static func render<V: View>(_ view: V, _ name: String, _ dir: URL) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.backgroundColor = NSColor(white: 0.5, alpha: 1)
        window.orderFrontRegardless()
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}
