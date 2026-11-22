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

    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "st.", "no.", "approx.", "inc.", "ltd."]

    private static let questionStarts: Set<String> = ["what", "why", "how", "when", "where", "who", "whom", "whose", "which",
        "can", "could", "would", "will", "should", "shall", "do", "does", "did", "is", "are", "am", "was", "were", "have", "has", "may"]

    /// Local punctuation rules the AI tends to skip: a missing full stop / question mark at the end of a sentence and a
    /// lowercase first letter. `skip` says whether a range is still being typed.
    static func punctuation(_ sentences: [Sentence], skip: (NSRange) -> Bool) -> [Issue] {
        var out: [Issue] = []
        for s in sentences {
            let words = WordDiff.words(s.text)
            guard words.count >= 4, let first = words.first, let last = words.last else { continue }
            // List items and quotes aren't held to sentence rules.
            if let c = first.word.first, "-*•>#".contains(c) || (first.word.dropLast().allSatisfy(\.isNumber) && ".)".contains(first.word.last!)) { continue }

            // End punctuation
            if let end = last.word.last, end.isLetter || end.isNumber {
                let range = NSRange(location: s.range.location + last.range.location, length: last.range.length)
                if !skip(NSRange(location: range.location, length: range.length + 1)) {
                    let question = questionStarts.contains(first.word.lowercased().trimmingCharacters(in: .punctuationCharacters))
                    out.append(Issue(range: range, kind: .punctuation, original: last.word, replacement: last.word + (question ? "?" : "."),
                                     explanation: question ? "This is a question, so end it with a question mark." : "End the sentence with a full stop."))
                }
            }

            // Capital letter at the start of each sentence, including ones the splitter missed ("done. we left").
            // Only plain lowercase words, so "iPhone" or "eBay" are left alone.
            for (k, word) in words.enumerated() {
                if k > 0 {
                    let prev = words[k - 1].word.lowercased()
                    guard let end = prev.last, ".!?".contains(end), !abbreviations.contains(prev),
                          !(prev.dropLast().contains(".")) else { continue }
                }
                let w = word.word
                if let c = w.first, c.isLowercase, c.isLetter, w.dropFirst().allSatisfy({ !$0.isUppercase }), w.count > 1 || c == "i" {
                    let range = NSRange(location: s.range.location + word.range.location, length: word.range.length)
                    if !skip(range) {
                        out.append(Issue(range: range, kind: .capitalization, original: w, replacement: w.prefix(1).uppercased() + w.dropFirst(),
                                         explanation: "Start a sentence with a capital letter."))
                    }
                }
            }
        }
        return out
    }

    /// How many UTF-16 units of the punctuation that `wanted` ends with (and `have` lacks) already follow `range`.
    /// "place" → "place." with ". Love…" after it: 1.
    static func punctuationAlreadyThere(after range: NSRange, in text: NSString, wanted: String, have: String) -> Int {
        let marks = CharacterSet(charactersIn: ".!?,;:…")
        func tail(_ s: String) -> String { String(s.reversed().prefix(while: { $0.unicodeScalars.allSatisfy(marks.contains) }).reversed()) }
        let want = tail(wanted.trimmingCharacters(in: .whitespaces)), got = tail(have.trimmingCharacters(in: .whitespaces))
        guard want.count > got.count, want.hasSuffix(got) || got.isEmpty else { return 0 }
        let extra = String(want.dropLast(got.count))
        let end = NSMaxRange(range)
        let len = (extra as NSString).length
        guard end + len <= text.length else { return 0 }
        let next = text.substring(with: NSRange(location: end, length: len))
        // Any sentence end already there counts: don't add "." after "?" or "!".
        if next == extra || (".!?".contains(extra) && len == 1 && ".!?".contains(next)) { return len }
        return 0
    }

    /// A fix must not add punctuation the text already has right after it ("improveing" → "improving." before a ".").
    static func withoutDoubledPunctuation(_ issue: Issue, in text: NSString) -> Issue? {
        guard !issue.kind.isSentenceLevel, NSMaxRange(issue.range) <= text.length else { return issue }
        let n = punctuationAlreadyThere(after: issue.range, in: text, wanted: issue.replacement, have: issue.original)
        guard n > 0 else { return issue }
        var i = issue
        i.replacement = String(i.replacement.dropLast(n))
        return i.replacement == i.original ? nil : i
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
        var dictionary: [String] = []
    }

    static func system(_ o: Options) -> String {
        var s = """
        You are the proofreader inside a Mac writing app. The user is typing in \(o.languageName). \
        You get numbered sentences and return the problems you find as JSON.

        Kinds:
        - "spelling": a misspelled word.
        - "grammar": a grammar, agreement, tense, article or word-form mistake.
        - "punctuation": a missing or wrong full stop, question mark, comma, apostrophe or other punctuation mark.
        - "capitalization": a missing capital letter (start of a sentence, names, "I") or a wrong one.
          For spelling, grammar, punctuation and capitalization, "original" is the shortest exact span that has to change (usually 1-3 words) and "replacement" is its fix.
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


        Look closely for the mistakes good editors catch most often:
        - Commonly confused words: their/there/they're, its/it's, your/you're, then/than, affect/effect, lose/loose, \
        who's/whose, fewer/less (fewer with things you can count), a/an.
        - Subject-verb agreement ("the list of items are" → "is"), verb tense that shifts for no reason, wrong word forms.
        - Missing or extra articles ("I went to store" → "the store").
        - Commas: after an introductory phrase ("After lunch we left" → "After lunch, we left"), before "but", "so" or "and" \
        joining two full sentences, around a name you're addressing ("Thanks John" → "Thanks, John"). Comma splices and \
        run-on sentences: split them or join them properly.
        - Apostrophes in contractions and possessives ("dont" → "don't", "the teams results" → "the team's results").
        - For clarity: wordy phrases, needless passive voice, repeated words, and sentences over about 30 words that \
        read better split in two.

        Rules:
        - Copy "original" character for character from the sentence.
        - Only report a mistake you're sure about. A missed suggestion is better than a wrong one.
        - "explanation" is one short, plain sentence (at most 12 words) saying why, for example "Use 'its' for possession, not 'it's'."
        - Wanted tone: \(o.tone.label). \(o.tone.guidance)
        - How strict: \(o.strictness.guidance)
        - Don't flag names, brands, product terms, URLs, code, emoji, or slang that suits the tone.
        - Never suggest swapping a correct word for a synonym, and never change the meaning, facts, names or numbers.
        - Only suggest a clarity rewrite when it is clearly easier to read, shorter or more natural. Keep the writer's words where they work.\(o.dictionary.isEmpty ? "" : "\n- Never flag these words from the user's dictionary: " + o.dictionary.prefix(200).joined(separator: ", ") + ".")
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

    /// Models often label a rewording as spelling or grammar. The label is checked against what actually changes:
    /// spelling only when the word really is misspelled; a correctly spelled word swapped for a look-alike or another
    /// form ("then" → "than", "go" → "went") is grammar; a different phrase with the same meaning ("waiting for" →
    /// "looking forward to") is a clarity improvement.
    static func verifiedKind(_ kind: IssueKind, original: String, replacement: String) -> IssueKind {
        guard kind == .spelling || kind == .grammar || kind == .capitalization else { return kind }
        let a = WordDiff.words(original).map(\.word), b = WordDiff.words(replacement).map(\.word)
        let letters = { (s: String) in s.lowercased().filter(\.isLetter) }
        if kind == .capitalization { return letters(original) == letters(replacement) ? kind : verifiedKind(.spelling, original: original, replacement: replacement) }
        let misspelled = a.contains { !WordDiff.isWord($0) }
        if kind == .spelling, misspelled { return .spelling }
        // Same letters, other spacing or apostrophes ("alot" → "a lot", "its" → "it's"): a real fix, keep it.
        if letters(original) == letters(replacement) { return kind }
        let shared = Set(a.map { $0.lowercased() }).intersection(b.map { $0.lowercased() })
        let lookAlike = a.count == 1 && b.count == 1 && (WordDiff.sameRoot(a[0], b[0]) || editDistance(a[0].lowercased(), b[0].lowercased()) <= 2)
        if lookAlike || !shared.isEmpty || a.count == 1 && b.count == 1 && a[0].count <= 3 { return misspelled ? .spelling : .grammar }
        return .clarity
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    /// Parses the reply and locates each issue in its sentence. Unlocatable or no-op issues are dropped.
    static func parse(_ raw: String, sentences: [Int: String]) -> [Int: [LocalIssue]]? {
        guard let data = extractJSONObject(raw), let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        var out: [Int: [LocalIssue]] = [:]
        for id in sentences.keys { out[id] = [] }
        for item in reply.issues {
            guard let text = sentences[item.sentence], var kind = IssueKind(rawValue: item.kind) else { continue }
            let original = item.original, replacement = item.replacement
            guard original != replacement, var r = TextTools.locate(original, in: text) else { continue }
            // Models often copy a sentence without its final full stop but write the fix with one: take the
            // punctuation that's really there into the span, so the fix doesn't add a second one.
            r.length += TextTools.punctuationAlreadyThere(after: r, in: text as NSString, wanted: replacement, have: original)
            let explanation = item.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            let found = (text as NSString).substring(with: r)
            if !kind.isSentenceLevel { kind = verifiedKind(kind, original: found, replacement: replacement) }
            if kind.isSentenceLevel {
                let chunks = WordDiff.changes(from: found, to: replacement)
                if chunks.isEmpty { continue }
                // One word swapped for another: a different form of the same word ("are" → "is") is a grammar fix;
                // anything else ("help" → "assistance") is a synonym swap, not an improvement.
                if chunks.count == 1, let c = chunks.first, WordDiff.words(c.original).count == 1, WordDiff.words(c.replacement).count == 1,
                   c.original.lowercased() != c.replacement.lowercased(), WordDiff.isWord(c.original), WordDiff.isWord(c.replacement) {
                    guard WordDiff.sameRoot(c.original, c.replacement) else { continue }
                    out[item.sentence, default: []].append(LocalIssue(location: r.location + c.range.location, length: c.range.length, kind: .grammar,
                                                                      original: c.original, replacement: c.replacement, explanation: explanation))
                    continue
                }
            }
            if kind.isSentenceLevel || WordDiff.words(found).count <= 4 {
                out[item.sentence, default: []].append(LocalIssue(location: r.location, length: r.length, kind: kind,
                                                                  original: found, replacement: replacement, explanation: explanation))
                continue
            }
            // A "small" fix that spans a long stretch (some models send the whole sentence): split it into the words
            // that actually changed, or treat it as a sentence rewrite when too much changed.
            let chunks = WordDiff.changes(from: found, to: replacement)
            if !chunks.isEmpty, chunks.count <= 4, chunks.allSatisfy({ WordDiff.words($0.original).count <= 3 && WordDiff.words($0.replacement).count <= 3 }) {
                for c in chunks {
                    out[item.sentence, default: []].append(LocalIssue(location: r.location + c.range.location, length: c.range.length, kind: kind,
                                                                      original: c.original, replacement: c.replacement,
                                                                      explanation: chunks.count == 1 ? explanation : ""))
                }
            } else if !chunks.isEmpty {
                out[item.sentence, default: []].append(LocalIssue(location: r.location, length: r.length, kind: .clarity,
                                                                  original: found, replacement: replacement, explanation: explanation))
            }
        }
        // Don't stack two sentence-level suggestions on one sentence.
        for (id, list) in out {
            var seenSentenceLevel = false
            out[id] = list.filter { i in
                guard i.kind.isSentenceLevel else { return true }
                defer { seenSentenceLevel = true }
                return !seenSentenceLevel
            }
        }
        return out
    }
}

/// Word-level diff, used to turn a rewritten span into the few words that changed.
enum WordDiff {
    struct Change: Equatable {
        var range: NSRange      // in the original text (UTF-16)
        var original: String
        var replacement: String
    }

    /// Words with their UTF-16 ranges (split on whitespace; punctuation stays attached).
    static func words(_ text: String) -> [(word: String, range: NSRange)] {
        let ns = text as NSString
        var out: [(String, NSRange)] = []
        var i = 0
        while i < ns.length {
            while i < ns.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: i)) ?? " ") { i += 1 }
            let start = i
            while i < ns.length, !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: i)) ?? " ") { i += 1 }
            if i > start { out.append((ns.substring(with: NSRange(location: start, length: i - start)), NSRange(location: start, length: i - start))) }
        }
        return out
    }

    static func isWord(_ w: String) -> Bool {
        let core = w.trimmingCharacters(in: .punctuationCharacters)
        guard !core.isEmpty else { return false }
        return NSSpellChecker.shared.checkSpelling(of: core, startingAt: 0).location == NSNotFound
    }

    /// Same dictionary root ("are"/"is" → be, "has"/"have" → have), or an article swap (a/an/the).
    static func sameRoot(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().trimmingCharacters(in: .punctuationCharacters), y = b.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let groups: [Set<String>] = [
            ["a", "an", "the"], ["am", "is", "are", "was", "were", "be", "been", "being"], ["has", "have", "had", "having"],
            ["do", "does", "did", "done"], ["its", "it's"], ["your", "you're"], ["there", "their", "they're"], ["then", "than"],
            ["to", "too"], ["whose", "who's"], ["affect", "effect"], ["lose", "loose"], ["this", "these"], ["that", "those"],
            ["much", "many"], ["less", "fewer"], ["who", "whom"], ["me", "i"], ["good", "well"], ["fell", "felt"],
        ]
        if groups.contains(where: { $0.contains(x) && $0.contains(y) }) { return true }
        if x.count > 3, y.count > 3, x.prefix(3) == y.prefix(3), abs(x.count - y.count) <= 3 { return true }   // go/goes, write/writes
        func lemma(_ w: String) -> String {
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = w
            return tagger.tag(at: w.startIndex, unit: .word, scheme: .lemma).0?.rawValue.lowercased() ?? w
        }
        return lemma(x) == lemma(y)
    }

    enum SegmentKind { case same, removed, added }

    /// The whole change as runs of kept, removed and added words (for showing a rewrite).
    static func segments(from original: String, to replacement: String) -> [(kind: SegmentKind, text: String)] {
        let a = words(original).map(\.word), b = words(replacement).map(\.word)
        let n = a.count, m = b.count
        guard n * m < 40_000 else { return [(.removed, original), (.added, replacement)] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [(SegmentKind, String)] = []
        func push(_ k: SegmentKind, _ w: String) {
            if let last = out.last, last.0 == k { out[out.count - 1].1 += " " + w } else { out.append((k, w)) }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { push(.same, a[i]); i += 1; j += 1 }
            else if j < m && (i >= n || dp[i][j + 1] >= dp[i + 1][j]) { push(.added, b[j]); j += 1 }
            else { push(.removed, a[i]); i += 1 }
        }
        // Show removals before additions where they sit side by side.
        var k = 0
        while k + 1 < out.count {
            if out[k].0 == .added, out[k + 1].0 == .removed { out.swapAt(k, k + 1) }
            k += 1
        }
        return out.map { (kind: $0.0, text: $0.1) }
    }

    static func changes(from original: String, to replacement: String) -> [Change] {
        let a = words(original), b = words(replacement).map(\.word)
        let n = a.count, m = b.count
        guard n > 0, n * m < 40_000 else { return [] }
        // LCS table
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i].word == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [Change] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i].word == b[j] { i += 1; j += 1; continue }
            let si = i, sj = j
            while (i < n || j < m) && !(i < n && j < m && a[i].word == b[j]) {
                if j < m && (i >= n || dp[i][j + 1] >= dp[i + 1][j]) { j += 1 } else { i += 1 }
            }
            let added = b[sj..<j].joined(separator: " ")
            if i > si {
                let r = NSUnionRange(a[si].range, a[i - 1].range)
                out.append(Change(range: r, original: (original as NSString).substring(with: r), replacement: added))
            } else if si > 0 {
                // Pure insertion: attach it to the word before.
                let prev = a[si - 1]
                out.append(Change(range: prev.range, original: prev.word, replacement: prev.word + " " + added))
            } else {
                let first = a[0]
                out.append(Change(range: first.range, original: first.word, replacement: added + " " + first.word))
            }
        }
        return out.filter { $0.original != $0.replacement }
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
    /// The app being typed in, for its tone setting.
    var appBundleID: String?
    /// Language detected from the text itself (when auto-detect is on).
    @Published private(set) var detected: WritingLanguage?
    private var cache: [String: [LocalIssue]] = [:]
    private var inFlight = Set<String>()
    private var requesting = false
    private var rerunAfterRequest = false
    private var debounce: DispatchWorkItem?
    private var settle: DispatchWorkItem?
    /// True once the user has paused typing, so the word at the cursor gets checked too.
    private var cursorSettled = false
    var dismissed = Set<String>()

    /// Called when the text changes. Updates marks right away, then schedules an AI pass.
    func textChanged(_ newText: String, cursor: Int?) {
        text = newText
        self.cursor = cursor
        detectLanguage()
        cursorSettled = false
        recompute()
        // A short pause after typing is enough to check the word under the cursor (no space needed).
        settle?.cancel()
        let s = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cursorSettled = true
            self.recompute()
        }
        settle = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: s)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runAI() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.checkDelay, execute: work)
    }

    func reset() {
        debounce?.cancel()
        settle?.cancel()
        text = ""
        cursor = nil
        detected = nil
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

    /// The language being checked: detected from the text, or the user's main language.
    var language: WritingLanguage {
        let s = AppSettings.shared
        return (s.autoDetectLanguage ? detected : nil) ?? s.language
    }

    var options: CheckPrompt.Options {
        let s = AppSettings.shared
        return .init(languageName: language.name, tone: s.tone(for: appBundleID), strictness: s.strictness,
                     toneCheck: s.toneCheck, dictionary: s.dictionary)
    }

    private func detectLanguage() {
        guard AppSettings.shared.autoDetectLanguage, text.filter(\.isLetter).count >= 25 else { return }
        let rec = NLLanguageRecognizer()
        rec.processString(String(text.suffix(2000)))
        guard let lang = rec.dominantLanguage?.rawValue,
              let conf = rec.languageHypotheses(withMaximum: 1).first?.value, conf > 0.6 else { return }
        let base = String(lang.prefix(2))
        let main = AppSettings.shared.language
        let found: WritingLanguage? = main.code.hasPrefix(base) ? main : WritingLanguage.all.first { $0.code.hasPrefix(base) }
        if found != detected { detected = found }
    }

    private func key(_ sentence: String) -> String {
        let o = options
        return "\(o.languageName)|\(o.tone.id)|\(o.tone.guidance.hashValue)|\(o.strictness.rawValue)|\(o.toneCheck)|\(sentence)"
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
        let dict = AppSettings.shared.dictionarySet
        ai.removeAll { !$0.kind.isSentenceLevel && dict.contains($0.original.lowercased()) }
        let spellAll = TextTools.spelling(text, language: language.spellCode, ignored: dict)
        // A spelling fix should be the closest real word: "improveing" → "improving" (spell checker) beats
        // "improve" (a small model). The AI keeps fixes that change more than spelling.
        ai.removeAll { a in
            guard a.kind == .spelling else { return false }
            let core = { (s: String) in s.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            return spellAll.contains { sp in
                NSIntersectionRange(sp.range, a.range).length > 0
                    && CheckPrompt.editDistance(core(sp.original), core(sp.replacement)) < CheckPrompt.editDistance(core(a.original), core(a.replacement))
            }
        }
        let wordLevelAI = ai.filter { !$0.kind.isSentenceLevel }
        let spell = spellAll
            .filter { sp in
                // The AI's own fix wins where both found something.
                !wordLevelAI.contains { NSIntersectionRange($0.range, sp.range).length > 0 }
            }
            .filter { !isBeingTyped($0.range) }
        var local = spell
        // Instant rules (doubled words, a/an, spacing, confused words, wordy phrases). The AI's and the spell
        // checker's fixes come first where they overlap; wordy phrases wait if the AI rewrote that sentence.
        let sentenceAI = ai.filter { $0.kind.isSentenceLevel }
        let ruleTaken = wordLevelAI + spell
        local += LocalRules.find(text, languageCode: language.spellCode, includeConciseness: AppSettings.shared.strictness != .relaxed)
            .filter { r in
                !isBeingTyped(r.range)
                    && !ruleTaken.contains { NSIntersectionRange($0.range, r.range).length > 0 }
                    && !(r.kind == .clarity && sentenceAI.contains { NSIntersectionRange($0.range, r.range).length > 0 })
            }
        if AppSettings.shared.strictness != .relaxed {
            let taken = ai.filter { !$0.kind.isSentenceLevel } + local
            local += TextTools.punctuation(sentences, skip: { isBeingTyped($0) })
                .filter { p in
                    // The AI's or spell checker's fix for the same word comes first; this one shows once that's fixed.
                    !taken.contains { NSIntersectionRange($0.range, p.range).length > 0 || $0.range.location == p.range.location }
                }
        }
        let s = AppSettings.shared
        let merged = (ai + local)
            .filter { !dismissed.contains($0.dismissKey) && !s.ignoredSuggestions.contains($0.dismissKey) && !s.disabledKinds.contains($0.kind) }
            .sorted { $0.range.location < $1.range.location }
        let withContext = merged.compactMap { TextTools.withoutDoubledPunctuation($0, in: text as NSString) }
            .map { Self.addContext($0, in: text as NSString) }
        if withContext != issues { issues = withContext }
    }

    /// Up to ~6 words on each side of the issue, within its line.
    static func addContext(_ issue: Issue, in text: NSString) -> Issue {
        var i = issue
        guard NSMaxRange(issue.range) <= text.length else { return i }
        let lineRange = text.lineRange(for: issue.range)
        let beforeRange = NSRange(location: lineRange.location, length: issue.range.location - lineRange.location)
        let afterStart = NSMaxRange(issue.range)
        let afterRange = NSRange(location: afterStart, length: max(0, NSMaxRange(lineRange) - afterStart))
        let beforeWords = text.substring(with: beforeRange).split(separator: " ", omittingEmptySubsequences: false)
        let afterText = text.substring(with: afterRange).trimmingCharacters(in: .newlines)
        let afterWords = afterText.split(separator: " ", omittingEmptySubsequences: false)
        i.before = (beforeWords.count > 6 ? "…" : "") + beforeWords.suffix(6).joined(separator: " ")
        i.after = afterWords.prefix(6).joined(separator: " ") + (afterWords.count > 6 ? "…" : "")
        return i
    }

    /// Don't flag the word the cursor is still in.
    private func isBeingTyped(_ r: NSRange) -> Bool {
        guard !cursorSettled, let c = cursor else { return false }
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
        // The on-device model is much slower: small batches, nearest sentences first.
        let s = AppSettings.shared
        pending = Array(pending.prefix(s.engine == .cloud && !s.provider.isLocal ? 20 : 4))

        let client: LLMClient
        do { client = try AI.client() } catch {
            status = (error as? AIError).map {
                switch $0 { case .noKey, .noModel, .noLocalModel: return .needsSetup; default: return .error($0.localizedDescription) }
            } ?? .error(error.localizedDescription)
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
                if result == nil {
                    failure = AIError.badResponse.localizedDescription
                    Log.write("unreadable AI reply (\(raw.count) chars, starts \(raw.prefix(1) == "{" ? "with {" : "without {"))", key: "ai")
                }
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
