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
    /// Dictionary completions for the word being typed, for the text they were looked up for.
    private var wordHint: (before: String, words: [String]) = ("", [])

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
        if let cached = cache[before], !cached.isEmpty { return show(cached, for: before) }
        // Mid-word: macOS's dictionary finishes the word at once (and gives the AI a hint), while the AI thinks.
        Task { [weak self] in
            let words = Self.partialWord(before).isEmpty ? [] : await Self.wordCompletions(before)
            guard let self, self.lastBefore == before else { return }
            self.wordHint = (before, words)
            if self.suggestion == nil, let local = Self.localWordSuggestion(before: before, completions: words) {
                self.show(local, for: before)
                if self.settings.completionLength == .word { return }   // the whole word is all that was asked for
            }
            if self.cache[before] != nil { return }
            let work = DispatchWorkItem { [weak self] in self?.request(before) }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    /// Enough text to go on: not right after a line break, and not at the start of a new sentence (guesses there are
    /// mostly noise). The current sentence needs a couple of words, or the user is in the middle of a word.
    static func worthSuggesting(_ before: String) -> Bool {
        guard let last = before.last, last != "\n" else { return false }
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.contains(where: \.isLetter) else { return false }
        if let end = trimmed.last, ".!?".contains(end) { return false }
        if looksLikeList(trimmed) { return false }
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
        let app = Coordinator.shared.frontApp
        let ctx = Context(bundleID: app?.bundleIdentifier, app: app?.localizedName, window: AX.windowTitle(el), field: AX.fieldLabel(el), after: after)
        let user = Self.request(before: before, context: ctx, length: settings.completionLength,
                                tone: settings.tone(for: app?.bundleIdentifier), language: Coordinator.shared.checker.language.name,
                                wordHint: wordHint.before == before ? wordHint.words : [])
        let length = settings.completionLength
        Task { [weak self] in
            let s: String
            if let local = client as? LocalClient {
                s = await Self.localSuggestion(before: before, context: ctx, length: length, path: local.path)
            } else {
                guard let raw = try? await client.complete(system: Self.system, messages: [.init(role: .user, text: user)], jsonSchema: Self.schema, purpose: .complete)
                else { return }
                s = Self.pick(raw, after: before, length: length)
            }
            guard let self, self.requested == before, self.lastBefore == before else { return }
            self.cache[before] = s
            if self.cache.count > 300 { self.cache.removeAll() }
            // They kept typing through a quick dictionary suggestion: leave it, this answer is for older text.
            if self.suggestion != nil, self.prefix != before { return }
            self.show(s, for: before)
        }
    }

    struct Context {
        var bundleID: String?
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
        // Finishing a half-typed word must make a real word ("invo" + "ice"), not a new misspelling.
        let partial = partialWord(before)
        if partial.count >= 2, before.last?.isLetter == true, !isWord(partial) {
            guard let f = s.first, f.isLetter, isWord(partial + s.prefix(while: \.isLetter)) else { return "" }
        }
        // Longer guesses need to be near-certain; short ones can be "very likely".
        if r.confidence == 4, s.split(separator: " ").count > 3 { return "" }
        if isGrounded(s, in: before) { return s }
        return groundedPrefix(s, in: before)
    }

    /// The part of a suggestion before its first invented fact ("is scheduled for Tuesday." → "is scheduled"), without
    /// a dangling small word at the end. Empty when too little is left to be worth showing.
    static func groundedPrefix(_ s: String, in before: String) -> String {
        var words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while !words.isEmpty, !isGrounded(words.joined(separator: " "), in: before) { words.removeLast() }
        while let last = words.last, last.isEmpty || dangling.contains(last.lowercased()) { words.removeLast() }
        let out = words.joined(separator: " ")
        return out.split(separator: " ").count >= 2 ? out : ""
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

    /// The fixed instructions. Everything that changes per request is in `request(...)`, so this part stays the same
    /// (and cacheable) across calls.
    static let system = """
    You are the inline autocomplete in a Mac writing app: the gray ghost text after the cursor that the user accepts \
    with Tab, like Smart Compose in Gmail. Predict, word for word, what this person is about to type next.

    A good suggestion is exactly what they were going to type, so accepting it feels like the app read their mind. \
    A wrong or odd suggestion is a distraction and costs trust. When you aren't sure, suggest nothing.

    You get a note on where they're writing and their text, with ⟦CURSOR⟧ marking the cursor.

    How to predict
    - Read all of the text first: who it's for, what it's about, the names and facts already given, and how they \
    write. The sentence the cursor is in matters most.
    - Finish their sentence the way they would: same person and tense, same spelling (US or UK), casing, punctuation \
    habits and formality. If they write casually in lowercase without full stops, so do you.
    - Choose the most common, expected words for this exact spot: set phrases ("as soon as possible", "let me know \
    if you have any questions") and the obvious next word. Never be creative, add a new idea or change direction.
    - Joined to their text, your words must be grammatical and make sense. Read their sentence with your words added \
    before you answer: "were taking too" → " long", never " slow".
    - Use only facts already in the text. Never invent names, numbers, dates, times, places, prices, topics or \
    details. If the next word would need a new fact ("due on" → a date, "a new approach to" → a topic), suggest nothing.
    - Lists and open-ended content ("Groceries: eggs, milk,") can't be predicted: suggest nothing.
    - If there is text after the cursor, your words go between the two and must flow into it. Don't repeat any of it.
    - Stop at a natural break: the end of the phrase or of the sentence. Never start a second sentence.

    The completion text
    - It's inserted exactly as written, at the cursor. Start exactly where their text stops and never repeat words \
    already written: "Let's ask" → " them", never "ask them".
    - Right after a space, don't start with a space. Right after a finished word or punctuation, start with a space.
    - Inside an unfinished word, start with the rest of that word and no space: "the late rep" → "ly". \
    Keep their spelling: after "colour", "prioriti" → "se".
    - Follow the length given with the text.

    Confidence
    - 5: nearly anyone would type exactly this here.
    - 4: the clear favourite; most people would.
    - 3 or less: plausible, but other words are about as likely. Then reply with confidence 1 and an empty completion.

    Reply with only JSON: {"completion": "...", "confidence": 1-5}

    Examples
    [email] I hope this email finds you⟦CURSOR⟧ → {"completion": " well.", "confidence": 5}
    [email] Let me know if you have any⟦CURSOR⟧ → {"completion": " questions.", "confidence": 5}
    [email] Sorry for the late rep⟦CURSOR⟧ → {"completion": "ly.", "confidence": 5}
    [email] Looking forward to ⟦CURSOR⟧ → {"completion": "hearing from you.", "confidence": 4}
    [email] I couldn't open the file you shared. Could you send me the⟦CURSOR⟧ → {"completion": " file again?", "confidence": 4}
    [email] The renewal is due on⟦CURSOR⟧ → {"completion": "", "confidence": 1}
    [chat] thanks so much!! you're the⟦CURSOR⟧ → {"completion": " best", "confidence": 5}
    [chat] running late, be there in⟦CURSOR⟧ → {"completion": "", "confidence": 1}
    [chat] We still don't know how they did it. Let's ask⟦CURSOR⟧ → {"completion": " them.", "confidence": 4}
    [chat] Could we ⟦CURSOR⟧ this to next week? → {"completion": "move", "confidence": 5}
    [document] We'll finalise the colour palette first, then prioriti⟦CURSOR⟧ → {"completion": "se", "confidence": 5}
    [document] The fix was simple, but it took us a long time to⟦CURSOR⟧ → {"completion": " find.", "confidence": 4}
    [document] There are three reasons this failed. The first is⟦CURSOR⟧ → {"completion": "", "confidence": 1}
    """

    /// The per-request message: where they're writing, the settings, and the text with the cursor marked.
    static func request(before: String, context: Context, length: CompletionLength, tone: Tone, language: String,
                        wordHint: [String] = []) -> String {
        let kind = WritingKind.detect(bundleID: context.bundleID, app: context.app, window: context.window)
        var whereLine = "Where: \(kind.label)"
        if let a = context.app { whereLine += " in \(a)" }
        var details: [String] = []
        if let w = context.window, !w.isEmpty { details.append("window “\(w.prefix(80))”") }
        if let f = context.field, !f.isEmpty { details.append("field “\(f.prefix(60))”") }
        if !details.isEmpty { whereLine += " (" + details.joined(separator: ", ") + ")" }

        var lines = [whereLine, "Style: \(kind.style)", "Language: \(language) · Tone: \(tone.label) (\(tone.guidance))",
                     "Length: \(length.rule)"]
        let partial = Self.partialWord(before)
        if !partial.isEmpty {
            let hint = wordHint.isEmpty ? "" : " Dictionary words that start this way: \(wordHint.prefix(4).joined(separator: ", "))."
            if partial.count > 1, isWord(partial) {
                lines.append("The cursor is right after “\(partial)”, which may be a finished word or the start of a longer one.\(hint)")
            } else {
                lines.append("The cursor is inside the unfinished word “\(partial)”.\(hint)")
            }
        }
        let text = String(before.suffix(1500)) + "⟦CURSOR⟧" + String(context.after.prefix(300))
        return lines.joined(separator: "\n") + "\n\nText:\n<<<\n" + text + "\n>>>"
    }

    // MARK: Local models: plain continuation

    /// Small local models can't follow an instruction prompt well, but they're very good at what they were trained on:
    /// continuing text. So the text is continued as is, and each word is kept only while the model is sure of it.
    static func localSuggestion(before: String, context: Context, length: CompletionLength, path: String) async -> String {
        // Plain continuation can't see text after the cursor: only suggest at the end of a line.
        let restOfLine = context.after.prefix(while: { $0 != "\n" })
        guard restOfLine.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let body = String(before.suffix(1500))
        let heal = Self.healPart(body)
        let lead = String(body.dropLast(heal.count))
        guard lead.contains(where: \.isLetter) else { return "" }
        var header = ""
        let kind = WritingKind.detect(bundleID: context.bundleID, app: context.app, window: context.window)
        if kind == .email, let w = context.window, !w.isEmpty, !["inbox", "gmail", "mail", "outlook"].contains(where: w.lowercased().contains) {
            header = "Subject: \(w.prefix(100))\n\n"
        }
        let maxTokens = length == .word ? 6 : length == .phrase ? 14 : 36
        let healCount = heal.count
        let steps = (try? await LlamaEngine.shared.continueText(path: path, prompt: header + lead, heal: heal, maxTokens: maxTokens) { text in
            Self.shouldStop(String(text.dropFirst(healCount)), length: length)
        }) ?? []
        return pickLocal(steps, heal: heal, before: before, length: length)
    }

    /// "Groceries: eggs, milk, bread," — the next item can't be predicted.
    static func looksLikeList(_ text: String) -> Bool {
        let line = text.split(separator: "\n").last.map(String.init) ?? text
        let tail = line.split(whereSeparator: { ".!?".contains($0) }).last.map(String.init) ?? line
        let items = tail.components(separatedBy: ",").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard items.count >= 2 else { return false }
        return items.dropLast().allSatisfy { $0.split(separator: " ").count <= 2 }
    }

    /// Words a suggestion shouldn't end on: something has to follow them.
    static let dangling: Set<String> = ["for", "to", "the", "a", "an", "of", "and", "or", "but", "with", "on", "in", "at", "by", "from",
                                        "about", "as", "that", "your", "my", "our", "their", "his", "her", "its", "this", "these", "if", "so"]

    /// The trailing spaces and half-typed word, cut from the prompt so the model can choose a whole-word token.
    static func healPart(_ text: String) -> String {
        let word = text.reversed().prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
        let spaces = text.dropLast(word.count).reversed().prefix(while: { $0 == " " || $0 == "\t" })
        return String(text.suffix(word.count + spaces.count))
    }

    nonisolated static func shouldStop(_ new: String, length: CompletionLength) -> Bool {
        if new.contains("\n") { return true }
        let words = new.split(whereSeparator: { $0 == " " }).count
        switch length {
        case .word:
            // A word is done once something other than a letter follows it.
            guard let i = new.firstIndex(where: \.isLetter) else { return false }
            return new[i...].contains { !$0.isLetter && $0 != "'" && $0 != "’" }
        case .phrase: return words > 6 || new.contains(where: { ".!?".contains($0) })
        case .sentence: return words > 20 || new.contains(where: { ".!?".contains($0) })
        }
    }

    /// Keeps the longest run of whole words whose combined likelihood stays above the bar.
    static func pickLocal(_ steps: [LlamaEngine.Step], heal: String, before: String, length: CompletionLength, bar: Double = 0.3) -> String {
        var full = ""
        var p = 1.0
        var best = ""
        for (i, step) in steps.enumerated() {
            full += step.text
            p *= step.p
            guard p >= bar else { break }
            guard full.count > heal.count else { continue }
            var new = String(full.dropFirst(heal.count))
            if let nl = new.firstIndex(of: "\n") { new = String(new[..<nl]); if !new.isEmpty { best = new }; break }
            // A cut is only good at the end of a word.
            let next = i + 1 < steps.count ? steps[i + 1].text.first : nil
            let atWordEnd = next == nil || !(next!.isLetter || next!.isNumber || next == "'" || next == "’")
            // …and not on a word that needs more after it ("questions or", "invoice for the").
            let last = new.split(separator: " ").last.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
            let firstWordOnly = !new.dropFirst().contains(" ")
            if atWordEnd, new.contains(where: \.isLetter), firstWordOnly || !Self.dangling.contains(last) { best = new }
        }
        // `.word` keeps just the first word (plus punctuation stuck to it).
        if length == .word { best = firstWord(of: best) }
        while let l = best.last, l.isWhitespace || ",;:".contains(l) { best.removeLast() }
        guard !best.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let partial = partialWord(before)
        if partial.count >= 2, before.last?.isLetter == true, !isWord(partial) {
            guard best.first?.isLetter == true, isWord(partial + best.prefix(while: \.isLetter)) else { return "" }
        }
        if isGrounded(best, in: before) { return best }
        return groundedPrefix(best, in: before)
    }

    /// The letters typed so far of the word at the end of `before` ("" after a space or punctuation).
    static func partialWord(_ before: String) -> String {
        String(before.reversed().prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" }).reversed())
            .trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
    }

    /// Dictionary completions of the word being typed, most common first, from macOS's own predictive text.
    static func wordCompletions(_ before: String) async -> [String] {
        let partial = partialWord(before)
        guard partial.count >= 2 else { return [] }
        let ns = before as NSString
        return await withCheckedContinuation { cont in
            let sc = NSSpellChecker.shared
            sc.requestCandidates(forSelectedRange: NSRange(location: ns.length, length: 0), in: before,
                                 types: NSTextCheckingResult.CheckingType.correction.rawValue | NSTextCheckingAllSystemTypes,
                                 options: nil, inSpellDocumentWithTag: 0) { _, results in
                let lower = partial.lowercased()
                var seen = Set<String>()
                let words = results.compactMap { r -> String? in
                    guard let w = r.replacementString?.trimmingCharacters(in: .whitespaces), w.count > partial.count,
                          w.lowercased().hasPrefix(lower), !w.contains(" "), seen.insert(w.lowercased()).inserted else { return nil }
                    return partial + w.dropFirst(partial.count)   // keep the case they typed
                }
                cont.resume(returning: words)
            }
        }
    }

    /// The rest of the current word to show at once, without waiting for the AI: only when what's typed isn't a word
    /// yet, so "ask" doesn't become "asking", but "invo" becomes "invoice".
    static func localWordSuggestion(before: String, completions: [String]) -> String? {
        let partial = partialWord(before)
        guard partial.count >= 3, before.last?.isLetter == true, !isWord(partial), let top = completions.first else { return nil }
        return String(top.dropFirst(partial.count))
    }

    /// Models often restart from the last whole word(s) ("Let's ask" → "ask them"). Drops the longest run of the text's
    /// final words that the reply opens with, so only the new part ("them") is left.
    static func stripEcho(_ s: String, after before: String) -> String {
        let body = s.drop(while: { $0 == " " })
        let tailWords = before.split(whereSeparator: { $0 == " " || $0 == "\n" }).suffix(6).map(String.init)
        guard !tailWords.isEmpty, !body.isEmpty else { return s }
        func norm(_ w: Substring) -> String { w.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        let replyWords = body.split(separator: " ", omittingEmptySubsequences: false)
        // Words that really do repeat in normal writing ("had had", "that that") only count as an echo with company.
        let doubles: Set<String> = ["had", "that", "is", "very", "so", "really", "no", "bye", "ha"]
        for n in stride(from: min(tailWords.count, replyWords.count), through: 1, by: -1) {
            let tail = tailWords.suffix(n).map { norm(Substring($0)) }
            let head = replyWords.prefix(n).map(norm)
            guard tail == head, !tail.contains("") else { continue }
            if n == 1, doubles.contains(tail[0]) { continue }
            // Ends exactly at a word boundary: drop those words (and the space after them).
            let dropped = replyWords.prefix(n).map(\.count).reduce(0, +) + (n - 1)
            var rest = String(body.dropFirst(dropped))
            if rest.isEmpty { return "" }
            // The cursor sits right after a letter: the next word needs its space back.
            if before.last?.isLetter == true, rest.first?.isLetter == true { rest = " " + rest }
            return rest
        }
        return s
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
        s = stripEcho(s, after: before)
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
            // Two whole words ("to" + "email") are a new word even when the spell checker accepts the join.
            let twoWords = word.count >= 2 && start.count >= 3 && isWord(word) && isWord(start) && !dictionaryFinishes(word, with: start)
            if !isWord(word + start) || twoWords { s = " " + s }
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

    /// True when the dictionary lists `word + rest` as a completion of `word` ("upd" → "update", but not "to" → "toemail").
    static func dictionaryFinishes(_ word: String, with rest: String) -> Bool {
        let joined = (word + rest).lowercased()
        let list = NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: (word as NSString).length),
                                                     in: word, language: nil, inSpellDocumentWithTag: 0) ?? []
        return list.contains { $0.lowercased() == joined }
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

/// What kind of writing the field holds, from the app and window title. Steers style: a chat reply is short and
/// casual, an email complete and polite.
enum WritingKind {
    case email, chat, document, social, code, other

    var label: String {
        switch self {
        case .email: "an email"
        case .chat: "a chat message"
        case .document: "a document or notes"
        case .social: "a social media post"
        case .code: "a code editor (comments, commit messages, docs)"
        case .other: "a text field"
        }
    }

    var style: String {
        switch self {
        case .email: "complete, polite sentences; common email phrases are very predictable."
        case .chat: "short and casual; copy their own style (lowercase, emoji, no full stop) exactly."
        case .document: "clear, complete sentences; don't add new ideas or content."
        case .social: "short and natural; don't add hashtags or new claims."
        case .code: "plain technical English; reuse the identifiers already in the text."
        case .other: "match their text."
        }
    }

    static func detect(bundleID: String?, app: String?, window: String?) -> WritingKind {
        let id = (bundleID ?? "").lowercased()
        let byApp: [(WritingKind, [String])] = [
            (.email, ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman", "com.mimestream", "it.bloop.airmail", "com.freron.mailmate", "com.hey"]),
            (.chat, ["com.tinyspeck.slackmacgap", "com.apple.mobilesms", "com.hnc.discord", "net.whatsapp", "ru.keepcoder.telegram", "org.telegram",
                     "com.microsoft.teams", "com.facebook.archon", "org.whispersystems.signal", "com.apple.facetime", "us.zoom.xos", "com.linear"]),
            (.code, ["com.microsoft.vscode", "com.apple.dt.xcode", "dev.zed", "com.todesktop.230313mzl4w4u92", "com.jetbrains", "com.sublimetext", "com.panic.nova", "com.github.githubclient", "com.git-tower"]),
            (.document, ["com.apple.notes", "com.apple.iwork.pages", "com.microsoft.word", "md.obsidian", "notion.id", "com.apple.textedit", "net.shinyfrog.bear",
                         "com.ulyssesapp", "pro.writer", "com.craft", "com.apple.freeform", "com.microsoft.powerpoint", "com.apple.iwork.keynote"]),
        ]
        for (kind, ids) in byApp where ids.contains(where: { id.hasPrefix($0) }) { return kind }
        // Browsers and other apps: the window title usually names the site.
        let t = (window ?? "").lowercased() + " " + (app ?? "").lowercased()
        let byTitle: [(WritingKind, [String])] = [
            (.email, ["gmail", "outlook", "inbox", "mail", "proton", "fastmail", "superhuman", "compose"]),
            (.chat, ["slack", "discord", "whatsapp", "messenger", "telegram", "teams", "messages", "chat", "intercom"]),
            (.social, ["twitter", " x ", "/ x", "linkedin", "reddit", "facebook", "threads", "bluesky", "mastodon", "instagram"]),
            (.code, ["github", "gitlab", "pull request", "stack overflow", "jira", "bitbucket"]),
            (.document, ["docs", "notion", "confluence", "document", "word", "medium", "substack", "wordpress", "dropbox paper", "quip", "coda"]),
        ]
        for (kind, words) in byTitle where words.contains(where: { t.contains($0) }) { return kind }
        return .other
    }
}
