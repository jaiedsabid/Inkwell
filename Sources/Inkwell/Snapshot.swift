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
        render(MenuContent().background(Color(nsColor: .windowBackgroundColor)), "menu", url)
        render(OnboardingView(finish: {}).background(Color(nsColor: .windowBackgroundColor)), "onboarding", url)
        for pane in SettingsPane.allCases {
            SettingsNav.shared.pane = pane
            render(SettingsView(), "settings-\(pane.rawValue)", url)
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
