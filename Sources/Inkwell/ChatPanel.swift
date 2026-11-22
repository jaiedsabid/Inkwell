import AppKit
import ApplicationServices
import SwiftUI

/// The "select text → ask for a change → refine → accept" panel.
@MainActor
final class ChatModel: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var prompt: String
        /// What's sent to the AI when it differs from what's shown (quick actions).
        var instruction: String? = nil
        /// A reply to the selected text rather than a new version of it.
        var isReply = false
        var result: String?
        var error: String?
        var sent: String { instruction ?? prompt }
    }

    @Published var source = ""
    @Published var turns: [Turn] = []
    @Published var input = ""
    @Published var loading = false
    @Published var sourceExpanded = false

    /// Where the text came from, so Accept can put the result back.
    var element: AXUIElement?
    var range: NSRange?
    var app: NSRunningApplication?
    var sourceEditable = true

    var latestResult: String? { turns.last?.result }
    /// Accept copies instead of replacing: for replies, and text Inkwell can't edit.
    var acceptCopies: Bool { turns.contains(where: \.isReply) || (!isWriteMode && !sourceEditable) }
    var isWriteMode: Bool { source.isEmpty }
    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        source = ""; turns = []; input = ""; loading = false; sourceExpanded = false
        element = nil; range = nil; app = nil; sourceEditable = true
    }

    func send(_ text: String? = nil) {
        let prompt = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !loading else { return }
        input = ""
        turns.append(Turn(prompt: prompt))
        run()
    }

    func send(_ action: QuickAction) {
        guard !loading else { return }
        turns.append(Turn(prompt: action.title, instruction: action.instruction, isReply: action.isReply))
        run()
    }

    func retry() {
        guard var last = turns.last else { return }
        last.result = nil; last.error = nil
        turns[turns.count - 1] = last
        run()
    }

    private func run() {
        let client: LLMClient
        do { client = try AI.client() } catch {
            turns[turns.count - 1].error = error.localizedDescription
            return
        }
        let s = AppSettings.shared
        let system = ChatPrompt.system(tone: s.tone(for: app?.bundleIdentifier), language: s.language.name, writeMode: isWriteMode)
        let messages = ChatPrompt.messages(source: source, turns: turns)
        loading = true
        task = Task { [weak self] in
            do {
                let out = try await client.complete(system: system, messages: messages, jsonSchema: nil, purpose: .chat)
                guard let self, !Task.isCancelled else { return }
                self.turns[self.turns.count - 1].result = ChatPrompt.clean(out)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.turns[self.turns.count - 1].error = error.localizedDescription
            }
            self?.loading = false
        }
    }
}

enum ChatPrompt {
    static func system(tone: Tone, language: String, writeMode: Bool) -> String {
        let task = writeMode
            ? "The user wants new text written, which will be inserted where their cursor is."
            : "The user selected some text and tells you how to change it."
        return """
        You are Inkwell, a writing assistant built into a Mac app. \(task)

        Reply with only the finished text: no intro, no quotes around it, no explanation, no markdown unless the original uses it. \
        Keep the original language (the user's main language is \(language)) unless they ask for a translation. \
        Keep names, facts, numbers, links and the layout (line breaks, lists) unless told otherwise. \
        Unless the user asks for something else, use this tone: \(tone.label). \(tone.guidance)
        When the user asks for a refinement, apply it to your latest version.
        """
    }

    static func messages(source: String, turns: [ChatModel.Turn]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for (i, t) in turns.enumerated() {
            if i == 0 {
                let text = source.isEmpty
                    ? "Instruction: \(t.sent)"
                    : "Text:\n<<<\n\(source)\n>>>\n\nInstruction: \(t.sent)"
                out.append(.init(role: .user, text: text))
            } else {
                out.append(.init(role: .user, text: t.sent))
            }
            if let r = t.result, i < turns.count - 1 { out.append(.init(role: .assistant, text: r)) }
        }
        return out
    }

    /// Strips wrappers some models add despite the instructions.
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<<<") { t = String(t.dropFirst(3)) }
        if t.hasSuffix(">>>") { t = String(t.dropLast(3)) }
        if t.count > 2, t.first == "\"", t.last == "\"", !t.dropFirst().dropLast().contains("\"") { t = String(t.dropFirst().dropLast()) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var settings = AppSettings.shared
    var accept: () -> Void
    var close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.source.isEmpty { sourceBox }
                        ForEach(model.turns) { turn in turnView(turn).id(turn.id) }
                        if model.turns.isEmpty { emptyHint }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: model.turns) { _, t in
                    if let last = t.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider().opacity(0.5)
            if !(model.isWriteMode && model.turns.isEmpty) { quickActions }
            inputBar
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line").foregroundStyle(Theme.accent).font(.system(size: 14, weight: .semibold))
            Text(model.isWriteMode ? "Write with Inkwell" : "Improve with Inkwell").font(.headline)
            Spacer()
            Menu {
                Picker("Tone", selection: $settings.tone) {
                    ForEach(Tone.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
            } label: {
                Label(settings.tone.label, systemImage: settings.tone.symbol).font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.system(size: 15)) }
                .buttonStyle(.plain)
                .help("Close (esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var sourceBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SELECTED TEXT").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Text(model.source)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(model.sourceExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { model.sourceExpanded.toggle() }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyHint: some View {
        Text(model.isWriteMode
             ? "Describe what to write, like “a polite reply saying I can't make Friday”."
             : "Say what to change, like “make it shorter” or “sound more confident”.")
            .font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func turnView(_ turn: ChatModel.Turn) -> some View {
        let isLast = turn.id == model.turns.last?.id
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 60)
                Text(turn.prompt)
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contextMenu {
                        if turn.instruction == nil {
                            Button("Save as a quick prompt") {
                                let title = turn.prompt.count > 24 ? String(turn.prompt.prefix(22)) + "…" : turn.prompt
                                settings.savedPrompts.append(SavedPrompt(title: title, instruction: turn.prompt))
                            }
                        }
                    }
            }
            if let result = turn.result {
                VStack(alignment: .leading, spacing: 10) {
                    Text(result).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if isLast {
                        HStack(spacing: 8) {
                            Button(action: accept) {
                                if model.acceptCopies {
                                    Label(model.turns.contains(where: \.isReply) ? "Copy reply" : "Copy", systemImage: "doc.on.doc")
                                } else {
                                    Label(model.isWriteMode ? "Insert" : "Accept", systemImage: "checkmark")
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.return, modifiers: .command)
                            if !model.acceptCopies {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(result, forType: .string)
                                } label: { Label("Copy", systemImage: "doc.on.doc") }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                            Spacer()
                            Text("Not quite? Type a change below.").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(12)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(isLast ? 1 : 0.55)
            } else if let err = turn.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if isLast { Button("Retry") { model.retry() }.buttonStyle(SecondaryButtonStyle()) }
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !model.isWriteMode && model.turns.isEmpty {
                    chip(QuickAction.reply)
                }
                ForEach(QuickAction.all) { chip($0) }
                Menu {
                    let main = settings.language
                    Button("\(main.name)") { model.send(QuickAction.translate(to: main.name)) }
                    Divider()
                    ForEach(WritingLanguage.all.filter { $0 != main }) { lang in
                        Button(lang.name) { model.send(QuickAction.translate(to: lang.name)) }
                    }
                } label: {
                    chipLabel("Translate", "globe")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(model.loading)
                ForEach(settings.savedPrompts) { p in
                    chip(QuickAction(title: p.title, symbol: "bookmark", instruction: p.instruction))
                }
            }
            .padding(.horizontal, 14).padding(.top, 10)
        }
    }

    private func chip(_ a: QuickAction) -> some View {
        Button { model.send(a) } label: { chipLabel(a.title, a.symbol) }
            .buttonStyle(.plain)
            .disabled(model.loading)
    }

    private func chipLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(model.turns.isEmpty ? (model.isWriteMode ? "What should I write?" : "What should I change?") : "Refine it…",
                      text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { model.send() }
            Button { model.send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundStyle(model.input.isEmpty || model.loading ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.input.isEmpty || model.loading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

@MainActor
final class ChatController {
    static let shared = ChatController()
    private let panel = FloatingPanel(allowKey: true)
    let model = ChatModel()

    init() {
        panel.level = .floating
        panel.host(ChatView(model: model, accept: { [weak self] in self?.accept() }, close: { [weak self] in self?.close() }))
    }

    var isOpen: Bool { panel.isVisible }

    /// Opens the panel for the current selection (or for writing new text at the cursor).
    func open() {
        if isOpen { close(); return }
        guard AX.isTrusted else { AppDelegate.shared?.showOnboarding(); return }
        let front = NSWorkspace.shared.frontmostApplication
        model.reset()
        model.app = front
        let el = AX.focusedElement()
        var anchor: CGRect?
        Task {
            if let el, !AX.isSecure(el) {
                model.element = el
                let sel = AX.selectedRange(el)
                var text = AX.selectedText(el) ?? ""
                if text.isEmpty, let sel, sel.length > 0, let v = AX.value(el) as NSString?, NSMaxRange(sel) <= v.length {
                    text = v.substring(with: sel)
                }
                if text.isEmpty, sel == nil || sel!.length > 0 { text = await Replacer.copySelection() ?? "" }
                model.source = text
                model.range = sel
                model.sourceEditable = AX.isEditableText(el) && sel != nil
                if let sel { anchor = AX.bounds(el, sel.length > 0 ? sel : NSRange(location: sel.location, length: 0))?.flippedToCocoa }
                if anchor == nil { anchor = AX.frame(el)?.flippedToCocoa }
            } else {
                model.source = await Replacer.copySelection() ?? ""
                model.sourceEditable = false
            }
            show(near: anchor)
        }
    }

    private func show(near anchor: CGRect?) {
        if let v = panel.contentView { panel.setContentSize(v.fittingSize) }
        if let a = anchor, a.width < 4000 {
            panel.place(near: a, gap: 10)
        } else if let s = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: s.visibleFrame.midX - panel.frame.width / 2, y: s.visibleFrame.midY))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        model.reset()
        panel.orderOut(nil)
    }

    private func accept() {
        guard let result = model.latestResult else { return }
        let el = model.element, range = model.range, source = model.source, app = model.app
        let editable = model.sourceEditable && !model.acceptCopies
        let isReply = model.turns.contains(where: \.isReply)
        Stats.shared.rewrite()
        panel.orderOut(nil)
        Task {
            app?.activate()
            try? await Task.sleep(nanoseconds: 150_000_000)
            var done = false
            if editable, let el, let range {
                if source.isEmpty {
                    // Write mode: insert at the cursor.
                    AX.setSelectedRange(el, NSRange(location: range.location, length: 0))
                    await Replacer.paste(result)
                    done = true
                } else {
                    done = await Replacer.replace(in: el, range: range, expected: source, with: result) != .failed
                }
            }
            if !done {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                Toast.shared.show(isReply ? "Reply copied. Click into the reply box and press ⌘V." : "Copied. Paste it with ⌘V.", duration: 4)
            }
            model.reset()
        }
    }
}

struct QuickAction: Identifiable {
    var title: String
    var symbol: String
    var instruction: String
    var isReply = false
    var id: String { title }

    static let reply = QuickAction(
        title: "Draft a reply", symbol: "arrowshape.turn.up.left",
        instruction: "The text above is a message I received. Write the reply I should send, in my tone. Reply with only the message itself.",
        isReply: true)

    static func translate(to language: String) -> QuickAction {
        .init(title: "Translate to \(language)", symbol: "globe",
              instruction: "Translate it into \(language). Keep the meaning, tone and formatting.")
    }

    static let all: [QuickAction] = [
        .init(title: "Fix grammar", symbol: "checkmark.circle", instruction: "Fix spelling, grammar and punctuation only. Change nothing else."),
        .init(title: "Shorter", symbol: "arrow.down.right.and.arrow.up.left", instruction: "Make it shorter. Keep the key points."),
        .init(title: "Longer", symbol: "arrow.up.left.and.arrow.down.right", instruction: "Make it a little longer and more complete, without adding facts."),
        .init(title: "Simpler", symbol: "text.badge.minus", instruction: "Use simpler words and shorter sentences."),
        .init(title: "Friendlier", symbol: "face.smiling", instruction: "Make it warmer and friendlier."),
        .init(title: "Professional", symbol: "briefcase", instruction: "Make it more professional and polished."),
        .init(title: "Confident", symbol: "bolt", instruction: "Make it sound more confident and direct. Remove hedging."),
    ]
}
