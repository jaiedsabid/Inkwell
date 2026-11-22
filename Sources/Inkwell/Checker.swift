import AppKit
import NaturalLanguage

struct Sentence: Equatable {
    var range: NSRange   // UTF-16, in the field text
    var text: String
}

/// An issue found by the AI, located relative to its sentence so it survives edits elsewhere in the text.
struct LocalIssue: Codable, Equatable {
    var location: Int
    var length: Int
    var kind: IssueKind
    var original: String
    var replacement: String
    var explanation: String
}

enum TextTools {
    static func sentences(_ text: String) -> [Sentence] {
        guard !text.isEmpty else { return [] }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var out: [Sentence] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let ns = NSRange(r, in: text)
            let s = String(text[r])
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed.contains(where: \.isLetter) else { return true }
            let lead = s.prefix(while: { $0.isWhitespace || $0.isNewline }).utf16.count
            out.append(Sentence(range: NSRange(location: ns.location + lead, length: trimmed.utf16.count), text: trimmed))
            return true
        }
        return out
    }

    /// Words that are clearly not prose: links, handles, code, numbers, acronyms.
    static func isSkippable(_ word: String) -> Bool {
        if word.count < 2 { return true }
        if word.contains(where: { $0.isNumber || "@#/_\\.:<>{}[]=".contains($0) }) { return true }
        if word.count <= 6, word == word.uppercased() { return true }
        return false
    }

    /// Fast, offline spelling check with the macOS spell checker.
    @MainActor
    static func spelling(_ text: String, language: String, ignored: Set<String>) -> [Issue] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var issues: [Issue] = []
        var start = 0
        while start < ns.length, issues.count < 200 {
            let r = checker.checkSpelling(of: text, startingAt: start, language: language, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
            guard r.location != NSNotFound, r.length > 0, r.location >= start else { break }
            let word = ns.substring(with: r)
            if !ignored.contains(word.lowercased()), !isSkippable(word) {
                let fix = checker.correction(forWordRange: r, in: text, language: language, inSpellDocumentWithTag: 0)
                    ?? checker.guesses(forWordRange: r, in: text, language: language, inSpellDocumentWithTag: 0)?.first
                if let fix, fix != word {
                    issues.append(Issue(range: r, kind: .spelling, original: word, replacement: fix, explanation: ""))
                }
            }
            start = NSMaxRange(r)
        }
        return issues
    }

    /// Finds `needle` in `haystack` (exact first, then ignoring case). UTF-16 range.
    static func locate(_ needle: String, in haystack: String) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let h = haystack as NSString
        var r = h.range(of: needle)
        if r.location == NSNotFound { r = h.range(of: needle, options: .caseInsensitive) }
        return r.location == NSNotFound ? nil : r
    }
}

// MARK: - AI prompt

enum CheckPrompt {
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "issues": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "sentence": ["type": "integer"],
                        "kind": ["type": "string", "enum": IssueKind.allCases.map(\.rawValue)],
                        "original": ["type": "string"],
                        "replacement": ["type": "string"],
                        "explanation": ["type": "string"],
                    ],
                    "required": ["sentence", "kind", "original", "replacement", "explanation"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["issues"],
        "additionalProperties": false,
    ]

    struct Options: Hashable {
        var languageName: String
        var tone: Tone
        var strictness: Strictness
        var toneCheck: Bool
    }

    static func system(_ o: Options) -> String {
        var s = """
        You are the proofreader inside a Mac writing app. The user is typing in \(o.languageName). \
        You get numbered sentences and return the problems you find as JSON.

        Kinds:
        - "spelling": a misspelled word.
        - "grammar": a grammar, agreement, tense, article, word-form or punctuation mistake.
          For spelling and grammar, "original" is the shortest exact span that has to change (usually 1-3 words) and "replacement" is its fix.
        - "clarity": the whole sentence is awkward, confusing, wordy or could be clearly better. "original" is the entire sentence exactly as given and "replacement" is the improved sentence, with any spelling and grammar fixes included. At most one clarity issue per sentence.
        """
        if o.toneCheck {
            s += """

            - "tone": the sentence doesn't fit the wanted tone (for example it sounds rude, cold, pushy or too casual). "original" is the entire sentence and "replacement" a version in the wanted tone. At most one tone issue per sentence, and not on the same sentence as a clarity issue.
            """
        } else {
            s += "\nNever use the kind \"tone\"."
        }
        s += """


        Rules:
        - Copy "original" character for character from the sentence.
        - "explanation" is one short, plain sentence (at most 12 words) saying why, for example "Use 'its' for possession, not 'it's'."
        - Wanted tone: \(o.tone.label). \(o.tone.guidance)
        - How strict: \(o.strictness.guidance)
        - Don't flag names, brands, product terms, URLs, code, emoji, or slang that suits the tone.
        - Write replacements in the same language as the sentence.
        - Leave out sentences that have nothing to fix. An empty list is a fine answer.
        """
        return s
    }

    static func user(_ sentences: [(id: Int, text: String)]) -> String {
        let items = sentences.map { ["id": $0.id, "text": $0.text] as [String: Any] }
        let data = (try? JSONSerialization.data(withJSONObject: ["sentences": items], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    struct Reply: Decodable {
        struct Item: Decodable {
            var sentence: Int
            var kind: String
            var original: String
            var replacement: String
            var explanation: String
        }
        var issues: [Item]
    }

    /// Parses the reply and locates each issue in its sentence. Unlocatable or no-op issues are dropped.
    static func parse(_ raw: String, sentences: [Int: String]) -> [Int: [LocalIssue]]? {
        guard let data = extractJSONObject(raw), let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        var out: [Int: [LocalIssue]] = [:]
        for id in sentences.keys { out[id] = [] }
        for item in reply.issues {
            guard let text = sentences[item.sentence], let kind = IssueKind(rawValue: item.kind) else { continue }
            let original = item.original, replacement = item.replacement
            guard original != replacement, let r = TextTools.locate(original, in: text) else { continue }
            out[item.sentence, default: []].append(LocalIssue(
                location: r.location, length: r.length, kind: kind,
                original: (text as NSString).substring(with: r), replacement: replacement,
                explanation: item.explanation.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return out
    }
}

// MARK: - Checker

/// Keeps the list of issues for the field being typed in. Spelling is instant and offline; the AI pass runs after a
/// short pause and is cached per sentence, so editing one sentence doesn't re-check the others.
@MainActor
final class Checker: ObservableObject {
    enum Status: Equatable { case idle, checking, needsSetup, error(String) }

    @Published private(set) var issues: [Issue] = []
    @Published private(set) var status: Status = .idle

    private(set) var text = ""
    private var cursor: Int?
    private var cache: [String: [LocalIssue]] = [:]
    private var inFlight = Set<String>()
    private var requesting = false
    private var rerunAfterRequest = false
    private var debounce: DispatchWorkItem?
    var dismissed = Set<String>()

    /// Called when the text changes. Updates marks right away, then schedules an AI pass.
    func textChanged(_ newText: String, cursor: Int?) {
        text = newText
        self.cursor = cursor
        recompute()
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runAI() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.checkDelay, execute: work)
    }

    func reset() {
        debounce?.cancel()
        text = ""
        cursor = nil
        if !issues.isEmpty { issues = [] }
    }

    func dismiss(_ issue: Issue) {
        dismissed.insert(issue.dismissKey)
        recompute()
    }

    /// Drops cached AI results, e.g. after the tone or language changed.
    func invalidate() {
        cache.removeAll()
        recompute()
        runAI()
    }

    var options: CheckPrompt.Options {
        let s = AppSettings.shared
        return .init(languageName: s.language.name, tone: s.tone, strictness: .standard, toneCheck: false)
    }

    private func key(_ sentence: String) -> String {
        let o = options
        return "\(o.languageName)|\(o.tone.rawValue)|\(o.strictness.rawValue)|\(o.toneCheck)|\(sentence)"
    }

    func recompute() {
        let sentences = TextTools.sentences(text)
        var ai: [Issue] = []
        for s in sentences {
            guard let local = cache[key(s.text)] else { continue }
            for l in local {
                ai.append(Issue(range: NSRange(location: s.range.location + l.location, length: l.length),
                                kind: l.kind, original: l.original, replacement: l.replacement, explanation: l.explanation))
            }
        }
        let wordLevelAI = ai.filter { !$0.kind.isSentenceLevel }
        let spell = TextTools.spelling(text, language: AppSettings.shared.language.spellCode, ignored: [])
            .filter { sp in
                // The AI's own fix wins where both found something.
                !wordLevelAI.contains { NSIntersectionRange($0.range, sp.range).length > 0 }
            }
            .filter { !isBeingTyped($0.range) }
        let merged = (ai + spell)
            .filter { !dismissed.contains($0.dismissKey) }
            .sorted { $0.range.location < $1.range.location }
        if merged != issues { issues = merged }
    }

    /// Don't flag the word the cursor is still in.
    private func isBeingTyped(_ r: NSRange) -> Bool {
        guard let c = cursor else { return false }
        return c >= r.location && c <= NSMaxRange(r)
    }

    private func runAI() {
        guard AppSettings.shared.isActive, !text.isEmpty else { return }
        if requesting { rerunAfterRequest = true; return }

        var pending = TextTools.sentences(text).filter { s in
            let k = key(s.text)
            return cache[k] == nil && !inFlight.contains(k) && s.text.count >= 3
        }
        guard !pending.isEmpty else { if status == .checking { status = .idle }; return }
        // Closest to the cursor first; cap the batch so replies stay fast.
        if let c = cursor {
            pending.sort { abs($0.range.location - c) < abs($1.range.location - c) }
        }
        pending = Array(pending.prefix(20))

        let client: LLMClient
        do { client = try AI.client() } catch {
            status = (error as? AIError).map { if case .noKey = $0 { return .needsSetup } else { return .error($0.localizedDescription) } } ?? .error(error.localizedDescription)
            return
        }

        var byID: [Int: String] = [:]
        var keys: [Int: String] = [:]
        for (i, s) in pending.enumerated() { byID[i + 1] = s.text; keys[i + 1] = key(s.text) }
        inFlight.formUnion(keys.values)
        requesting = true
        status = .checking
        let system = CheckPrompt.system(options)
        let user = CheckPrompt.user(byID.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })

        Task { [weak self] in
            var result: [Int: [LocalIssue]]?
            var failure: String?
            do {
                let raw = try await client.complete(system: system, messages: [.init(role: .user, text: user)],
                                                    jsonSchema: CheckPrompt.schema, purpose: .check)
                result = CheckPrompt.parse(raw, sentences: byID)
                if result == nil { failure = AIError.badResponse.localizedDescription }
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            if let result {
                for (id, list) in result { if let k = keys[id] { self.cache[k] = list } }
                if self.cache.count > 3000 { self.cache.removeAll() }
            }
            self.inFlight.subtract(keys.values)
            self.requesting = false
            self.status = failure.map { .error($0) } ?? .idle
            self.recompute()
            if self.rerunAfterRequest { self.rerunAfterRequest = false; self.runAI() }
        }
    }
}
