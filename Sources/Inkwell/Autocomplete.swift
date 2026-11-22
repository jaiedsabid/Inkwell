import AppKit
import ApplicationServices

enum CompletionLength: String, CaseIterable, Codable, Identifiable {
    case word, phrase, sentence
    var id: String { rawValue }
    var label: String {
        switch self {
        case .word: "Next word"
        case .phrase: "Short phrase"
        case .sentence: "Rest of sentence"
        }
    }
    var rule: String {
        switch self {
        case .word: "Only the next word (or the rest of the current word if it's unfinished)."
        case .phrase: "The next few words, at most 6."
        case .sentence: "The rest of the current sentence, at most 20 words."
        }
    }
}

/// Gray "ghost text" after the cursor predicting what the user will type next. Tab accepts it, → accepts one word,
/// Esc dismisses it. Keeps working while the user types the same letters ("type-through").
@MainActor
final class Autocomplete {
    static let shared = Autocomplete()

    /// Read by the keyboard tap, which runs outside the main actor's bookkeeping.
    nonisolated(unsafe) static var ghostVisible = false
    nonisolated(unsafe) static var cursorAtTextEnd = false
    nonisolated(unsafe) private static var tapRef: CFMachPort?

    weak var overlay: OverlayController?
    private(set) var suggestion: String?
    private var prefix = ""              // text before the cursor when the suggestion was made / last advanced
    private var lastBefore = ""
    private var requested: String?
    private var element: AXUIElement?
    private var debounce: DispatchWorkItem?
    private var cache: [String: String] = [:]
    private var acceptedWords = 0

    private var settings: AppSettings { AppSettings.shared }

    // MARK: Keyboard

    /// Installs the keyboard tap (needs Accessibility). Safe to call again.
    func installKeyTap() {
        guard Self.tapRef == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = Autocomplete.tapRef { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, Autocomplete.ghostVisible else { return Unmanaged.passUnretained(event) }
            let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            guard mods.isEmpty else { return Unmanaged.passUnretained(event) }
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 48:   // Tab: accept all
                DispatchQueue.main.async { MainActor.assumeIsolated { Autocomplete.shared.accept(all: true) } }
                return nil
            case 124 where Autocomplete.cursorAtTextEnd:   // →: accept one word
                DispatchQueue.main.async { MainActor.assumeIsolated { Autocomplete.shared.accept(all: false) } }
                return nil
            case 53:   // Esc: dismiss
                DispatchQueue.main.async { MainActor.assumeIsolated { Autocomplete.shared.dismiss() } }
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }, userInfo: nil) else { return }
        Self.tapRef = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: Tracking

    /// Called on every focus tick with the field's current text and selection.
    func update(element el: AXUIElement, value: String, selection: NSRange?) {
        guard settings.autocomplete, settings.isActive else { return dismiss(reset: true) }
        if element == nil || !CFEqual(element!, el) { dismiss(reset: true); element = el }
        guard let sel = selection, sel.length == 0 else { return dismiss() }

        let ns = value as NSString
        let c = min(sel.location, ns.length)
        let atLineEnd = c == ns.length || ns.character(at: c) == 10
        Self.cursorAtTextEnd = c == ns.length || ns.substring(from: c).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let before = ns.substring(to: c)

        if let s = suggestion {
            if before == prefix { return layout() }                     // nothing changed: keep it in place
            if before.hasPrefix(prefix) {
                let typed = String(before.dropFirst(prefix.count))
                if s.hasPrefix(typed), typed.count < s.count {           // typing the suggested letters
                    suggestion = String(s.dropFirst(typed.count))
                    prefix = before
                    return layout()
                }
            }
            dismiss()
        }

        guard before != lastBefore else { return }
        lastBefore = before
        debounce?.cancel()
        guard atLineEnd, Self.worthSuggesting(before) else { return }
        if let cached = cache[before] { return show(cached, for: before) }
        let work = DispatchWorkItem { [weak self] in self?.request(before) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Enough text to go on: not right after a line break, and not at the start of a new sentence (guesses there are
    /// mostly noise). The current sentence needs a couple of words, or the user is in the middle of a word.
    static func worthSuggesting(_ before: String) -> Bool {
        guard let last = before.last, last != "\n" else { return false }
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.contains(where: \.isLetter) else { return false }
        if let end = trimmed.last, ".!?".contains(end) { return false }
        let sentence = trimmed.split(whereSeparator: { ".!?\n".contains($0) }).last.map(String.init) ?? trimmed
        let words = sentence.split(separator: " ")
        let midWord = last.isLetter && (words.last?.count ?? 0) >= 3
        return words.count >= 2 || midWord
    }

    func dismiss(reset: Bool = false) {
        debounce?.cancel()
        if suggestion != nil { suggestion = nil; overlay?.ghost = nil }
        Self.ghostVisible = false
        if reset { lastBefore = ""; requested = nil; element = nil }
    }

    // MARK: Requesting

    private func request(_ before: String) {
        guard before == lastBefore, let client = try? AI.client(), let el = element else { return }
        requested = before
        let after: String = {
            guard let v = AX.value(el) as NSString?, (before as NSString).length <= v.length else { return "" }
            return String(v.substring(from: (before as NSString).length).prefix(300))
        }()
        let ctx = Context(app: Coordinator.shared.frontApp?.localizedName, window: AX.windowTitle(el), field: AX.fieldLabel(el), after: after)
        let system = Self.prompt(length: settings.completionLength, tone: settings.tone(for: Coordinator.shared.frontApp?.bundleIdentifier),
                                 language: Coordinator.shared.checker.language.name, context: ctx)
        let user = "Text before the cursor:\n<<<\n\(before.suffix(1500))\n>>>"
        Task { [weak self] in
            let raw = try? await client.complete(system: system, messages: [.init(role: .user, text: user)], jsonSchema: Self.schema, purpose: .complete)
            guard let self, let raw, self.requested == before, self.lastBefore == before else { return }
            let s = Self.pick(raw, after: before, length: self.settings.completionLength)
            self.cache[before] = s
            if self.cache.count > 300 { self.cache.removeAll() }
            self.show(s, for: before)
        }
    }

    struct Context {
        var app: String?
        var window: String?
        var field: String?
        var after: String = ""
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["completion": ["type": "string"], "confidence": ["type": "integer"]],
        "required": ["completion", "confidence"],
        "additionalProperties": false,
    ]

    /// Only confident, clean, grounded suggestions survive.
    static func pick(_ raw: String, after before: String, length: CompletionLength) -> String {
        struct Reply: Decodable { var completion: String; var confidence: Int }
        guard let data = extractJSONObject(raw), let r = try? JSONDecoder().decode(Reply.self, from: data), r.confidence >= 4 else { return "" }
        let s = clean(r.completion, after: before, length: length)
        // Longer guesses need to be near-certain; short ones can be "very likely".
        if r.confidence == 4, s.split(separator: " ").count > 3 { return "" }
        return isGrounded(s, in: before) ? s : ""
    }

    /// Rejects suggestions that bring in facts the user never wrote (numbers, names, links) or repeat what's there.
    static func isGrounded(_ s: String, in before: String) -> Bool {
        let lower = before.lowercased()
        let tokens = s.split(whereSeparator: { $0 == " " }).map(String.init)
        for (i, t) in tokens.enumerated() {
            let core = t.trimmingCharacters(in: .punctuationCharacters)
            if core.isEmpty { continue }
            if core.contains(where: \.isNumber), !before.contains(core) { return false }
            if t.contains("@") || t.contains("://") || t.hasPrefix("www.") { return false }
            // A capitalized word mid-sentence that isn't in the text is likely an invented name.
            let startsSentence = i == 0 ? (before.trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } ?? true)
                                        : tokens[i - 1].last.map { ".!?".contains($0) } ?? false
            if let f = core.first, f.isUppercase, core != "I", !startsSentence, !lower.contains(core.lowercased()) { return false }
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        if tokens.count >= 3, lower.contains(trimmed) { return false }
        return true
    }

    private func show(_ s: String, for before: String) {
        guard !s.isEmpty, before == lastBefore else { return }
        suggestion = s
        prefix = before
        layout()
    }

    static func prompt(length: CompletionLength, tone: Tone, language: String, context: Context = Context()) -> String {
        var where_: [String] = []
        if let a = context.app { where_.append("App: \(a)") }
        if let w = context.window, !w.isEmpty { where_.append("Window: \(w)") }
        if let f = context.field { where_.append("Field: \(f)") }
        let afterLine = context.after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "" : "\nText after the cursor (don't repeat it): \(context.after)"
        return """
        You are the autocomplete in a Mac writing app, like the gray text that finishes sentences in Gmail. \
        Predict the words the user is most likely to type next at the cursor.

        Where they're writing: \(where_.isEmpty ? "unknown" : where_.joined(separator: " · "))\(afterLine)
        Language: usually \(language). Tone: \(tone.label) (\(tone.guidance))

        Reply as JSON: {"completion": "...", "confidence": 1-5}
        - completion: the exact text to insert at the cursor. Length: \(length.rule)
        - Continue the thought they started. Use only what the text already implies: never invent names, numbers, dates, places or facts.
        - Prefer the most common, natural continuation over a creative one. Match their spelling, casing and style.
        - If the last word is unfinished, reply with only its missing letters and what follows, with no leading space: \
        "AI m" → "odel", never "model". Otherwise start with a space.
        - Stop at a natural break: the end of a phrase or sentence.
        - confidence: how likely they'd type exactly this. 5 = almost certain, 4 = very likely, 3 or less = a guess. \
        When it would only be a guess, use 1 and an empty completion.

        Examples:
        "Let me know if you have any" → {"completion": " questions.", "confidence": 5}
        "Looking forward to" → {"completion": " hearing from you.", "confidence": 4}
        "Thanks for the upd" → {"completion": "ate", "confidence": 5}
        "We trained a new AI m" → {"completion": "odel", "confidence": 4}
        "The quarterly numbers show that" → {"completion": "", "confidence": 1}
        "I wanted to follow up on" → {"completion": " our conversation", "confidence": 4}
        """
    }

    /// Tidies a reply into text that can be inserted after `before`.
    static func clean(_ raw: String, after before: String, length: CompletionLength) -> String {
        var s = raw.replacingOccurrences(of: "\r", with: "")
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }              // one line only
        for wrap in ["\"", "“", "”", "<<<", ">>>", "`"] where s.trimmingCharacters(in: .whitespaces).hasPrefix(wrap) {
            s = s.replacingOccurrences(of: wrap, with: "")
        }
        // The model sometimes repeats the end of the text before continuing.
        let tail = String(before.suffix(40))
        if let r = s.range(of: tail), r.lowerBound == s.startIndex { s = String(s[r.upperBound...]) }
        if before.last?.isWhitespace == true { s = String(s.drop(while: { $0 == " " })) }
        // Half-typed word: models often send the whole word ("m" → "model") instead of the rest ("odel").
        if let last = before.last, last.isLetter {
            let partial = String(before.reversed().prefix(while: \.isLetter).reversed())
            let body = s.drop(while: { $0 == " " })
            let hadSpace = body.count != s.count
            let partialIsWord = partial.count == 1 ? ["a", "i"].contains(partial.lowercased()) : isWord(partial)
            if body.lowercased().hasPrefix(partial.lowercased()), body.count > partial.count, !hadSpace || !partialIsWord {
                s = String(body.dropFirst(partial.count))
            }
        }
        if let last = before.last, ".,!?;:".contains(last), let first = s.first, first.isLetter { s = " " + s }
        // Models often forget the space before a new word. Joining is right only when it finishes a real word
        // ("Thank" + "s"); otherwise ("the" + "file") a space is missing.
        if let last = before.last, last.isLetter, let first = s.first, first.isLetter {
            let word = String(before.reversed().prefix(while: \.isLetter).reversed())
            let start = String(s.prefix(while: \.isLetter))
            if !isWord(word + start) { s = " " + s }
        }
        s = String(s.prefix(length == .sentence ? 160 : 80))
        while s.last?.isWhitespace == true { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? "" : s
    }

    // MARK: Showing

    private func layout() {
        guard let el = element, let s = suggestion, !prefix.isEmpty else { return dismiss() }
        let idx = (prefix as NSString).length
        guard let caret = AX.bounds(el, NSRange(location: idx - 1, length: 1)), caret.height > 2 else { return dismiss() }
        let field = AX.frame(el)
        let width = max(0, (field?.maxX ?? caret.maxX + 400) - caret.maxX - 6)
        guard width > 20 else { return dismiss() }
        let size = AX.fontSize(el, at: idx - 1) ?? max(11, caret.height * 0.78)
        let rect = CGRect(x: caret.maxX, y: caret.minY, width: width, height: caret.height).flippedToCocoa
        overlay?.ghost = Ghost(text: s, rect: rect, fontSize: size)
        Self.ghostVisible = true
    }

    // MARK: Accepting

    func accept(all: Bool) {
        guard let el = element, let s = suggestion else { return }
        let text = all ? s : Self.firstWord(of: s)
        let before = AX.value(el)
        let ok = AX.setSelectedText(el, text)
        let remainder = all ? "" : String(s.dropFirst(text.count))
        prefix += text
        lastBefore = prefix
        suggestion = remainder.isEmpty ? nil : remainder
        if suggestion == nil { overlay?.ghost = nil; Self.ghostVisible = false }
        acceptedWords += Stats.wordCount(text)
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            // Some apps ignore setting the text through Accessibility: type it with a paste instead.
            if !ok || AX.value(el) == before { await Replacer.paste(text) }
            self.layout()
        }
    }

    static func isWord(_ w: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0).location == NSNotFound
    }

    /// Leading spaces plus the first word (and punctuation stuck to it).
    static func firstWord(of s: String) -> String {
        let lead = s.prefix(while: { $0 == " " })
        let rest = s.dropFirst(lead.count)
        return String(lead) + String(rest.prefix(while: { $0 != " " }))
    }
}

/// Gray suggested text drawn after the cursor.
struct Ghost: Equatable {
    var text: String
    var rect: CGRect      // Cocoa screen coordinates: from the cursor to the field's right edge, one line tall
    var fontSize: CGFloat
}
