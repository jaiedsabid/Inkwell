import Foundation

/// Instant, offline English checks for mistakes with one clear fix: doubled words, "a"/"an", spacing around
/// punctuation, a lowercase "I", commonly confused words, a missing comma after an introductory word, and wordy
/// phrases. They run on every keystroke, so they show before (and without) the AI.
enum LocalRules {
    struct Rule {
        var pattern: String
        var kind: IssueKind
        var caseSensitive = false
        var explanation: String
        /// The whole match → its replacement; nil skips the match.
        var fix: (_ match: String, _ groups: [String]) -> String?
    }

    static func find(_ text: String, languageCode: String, includeConciseness: Bool) -> [Issue] {
        guard languageCode.hasPrefix("en"), !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [Issue] = []
        for rule in rules where includeConciseness || rule.kind != .clarity {
            guard let re = cache(rule.pattern, rule.caseSensitive) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range
                let match = ns.substring(with: r)
                if insideCodeOrLink(ns, r) { continue }
                let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
                guard var fix = rule.fix(match, groups), fix != match else { continue }
                fix = matchCase(fix, like: match)
                guard fix != match else { continue }
                out.append(Issue(range: r, kind: rule.kind, original: match, replacement: fix, explanation: rule.explanation))
            }
        }
        // One issue per spot: earlier rules in the list win.
        var taken: [NSRange] = []
        return out.filter { i in
            if taken.contains(where: { NSIntersectionRange($0, i.range).length > 0 }) { return false }
            taken.append(i.range)
            return true
        }
    }

    // MARK: - Rules

    /// Words that really do appear twice in a row.
    private static let realDoubles: Set<String> = ["had", "that", "is", "very", "so", "really", "no", "bye", "ha", "do", "can", "blah", "knock", "well", "now", "go", "yes", "many", "more"]

    static let rules: [Rule] = [
        Rule(pattern: #"\b([A-Za-z]+) +(\1)\b"#, kind: .grammar, explanation: "This word appears twice.") { _, g in
            realDoubles.contains(g[1].lowercased()) ? nil : g[1]
        },
        Rule(pattern: #"\b(could|would|should|must|might|may) of\b"#, kind: .grammar, explanation: "Use “have” here, not “of”.") { _, g in
            g[1] + " have"
        },
        Rule(pattern: #"\b(more|less|better|worse|rather|bigger|smaller|faster|slower|higher|lower|greater|larger|longer|shorter|easier|harder|cheaper|stronger|smarter|other) then\b"#,
             kind: .grammar, explanation: "Use “than” to compare.") { _, g in
            g[1] + " than"
        },
        Rule(pattern: #"\bits (a|an|the|been|not|going|important|possible|true|just|so|very|really|getting|hard|easy|good|great|okay|ok|fine|done|over|all)\b"#,
             kind: .grammar, explanation: "“It's” means “it is”; “its” shows possession.") { _, g in
            "it's " + g[1]
        },
        Rule(pattern: #"\bit's own\b"#, kind: .grammar, explanation: "Use “its” to show possession.") { _, _ in "its own" },
        Rule(pattern: #"\byour (welcome|going|gonna|right that|not)\b"#, kind: .grammar, explanation: "“You're” means “you are”.") { _, g in
            "you're " + g[1]
        },
        Rule(pattern: #"\btheir (is|are|was|were|will be|has been|have been)\b"#, kind: .grammar, explanation: "Use “there” for “there is / there are”.") { _, g in
            "there " + g[1]
        },
        Rule(pattern: #"\b(alot|irregardless|could care less)\b"#, kind: .grammar, explanation: "This is a common mistake.") { m, _ in
            ["alot": "a lot", "irregardless": "regardless", "could care less": "couldn't care less"][m.lowercased()]
        },
        Rule(pattern: #"\b(a|an) ([A-Za-z][A-Za-z'-]*)"#, kind: .grammar, explanation: "Use “an” before a vowel sound and “a” before a consonant sound.") { _, g in
            let word = g[2]
            if word.count > 1, word == word.uppercased() { return nil }        // acronyms: "an FAQ" / "a FAQ" both seen
            let wantAn = needsAn(word)
            let isAn = g[1].lowercased() == "an"
            guard wantAn != isAn else { return nil }
            return (wantAn ? "an " : "a ") + word
        },
        Rule(pattern: #"\bi('m|'ve|'ll|'d|’m|’ve|’ll|’d)?\b(?!\.e|-)"#, kind: .capitalization, caseSensitive: true, explanation: "Always write “I” as a capital letter.") { m, _ in
            "I" + m.dropFirst()
        },
        Rule(pattern: #"([A-Za-z0-9)\]"']+) +([,;:!?.])(?=\s|$)"#, kind: .punctuation, explanation: "Remove the space before the punctuation mark.") { _, g in
            g[1] + g[2]
        },
        Rule(pattern: #"([a-z]{2,})([,;])([A-Za-z]{2,})"#, kind: .punctuation, explanation: "Add a space after the punctuation mark.") { _, g in
            g[1] + g[2] + " " + g[3]
        },
        Rule(pattern: #"([A-Za-z,.;:!?])  +(?=[A-Za-z])"#, kind: .punctuation, explanation: "Remove the extra space.") { _, g in
            g[1] + " "
        },
        Rule(pattern: #"(?:^|(?<=[.!?]\s)|(?<=\n))(However|Therefore|Moreover|Furthermore|Nevertheless|Unfortunately|Fortunately|Additionally|Consequently|Meanwhile|Otherwise|Honestly|Personally|Similarly|Likewise|Hopefully|In addition|In fact|For example|For instance|As a result|On the other hand|By the way|In other words|In general)(?= (?!of\b|to\b)[a-z])"#,
             kind: .punctuation, caseSensitive: true, explanation: "Add a comma after an introductory word or phrase.") { m, _ in
            m + ","
        },
    ] + wordy.map { phrase, short in
        Rule(pattern: "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b", kind: .clarity,
             explanation: short.isEmpty ? "This word adds nothing here." : "Say it in fewer words.") { _, _ in short }
    }

    /// Wordy phrase → shorter form (conciseness).
    static let wordy: [(String, String)] = [
        ("due to the fact that", "because"), ("in spite of the fact that", "although"), ("despite the fact that", "although"),
        ("at this point in time", "now"), ("at the present time", "now"), ("in order to", "to"), ("for the purpose of", "for"),
        ("in the event that", "if"), ("has the ability to", "can"), ("have the ability to", "can"), ("is able to", "can"),
        ("are able to", "can"), ("a large number of", "many"), ("the majority of", "most"), ("in the near future", "soon"),
        ("each and every", "every"), ("first and foremost", "first"), ("very unique", "unique"), ("absolutely essential", "essential"),
        ("end result", "result"), ("past history", "history"), ("basic fundamentals", "fundamentals"), ("close proximity", "proximity"),
        ("free gift", "gift"), ("revert back", "revert"), ("repeat again", "repeat"), ("advance planning", "planning"),
        ("with regard to", "about"), ("with regards to", "about"), ("in regard to", "about"), ("on a daily basis", "daily"),
        ("on a weekly basis", "weekly"), ("in close proximity to", "near"), ("prior to", "before"), ("subsequent to", "after"),
        ("make a decision", "decide"), ("give consideration to", "consider"), ("take into consideration", "consider"),
    ].map { ($0.0, $0.1) }

    /// "an hour", "a user": by sound, not letter.
    static func needsAn(_ word: String) -> Bool {
        let w = word.lowercased()
        if ["hour", "honest", "honor", "honour", "heir"].contains(where: w.hasPrefix) { return true }
        let soundsLikeYou = ["unicorn", "uniform", "unif", "union", "unique", "unit", "univers", "unisex", "unilat", "usual", "use",
                             "user", "uter", "util", "utop", "uran", "urin", "euro", "eu", "ewe", "ufo", "ukulele", "ubiq", "unanim"]
        if soundsLikeYou.contains(where: w.hasPrefix) || w.hasPrefix("one") || w.hasPrefix("once") { return false }
        guard let f = w.first else { return false }
        return "aeiou".contains(f)
    }

    // MARK: - Helpers

    nonisolated(unsafe) private static var compiled: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    private static func cache(_ pattern: String, _ caseSensitive: Bool) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        let key = (caseSensitive ? "1" : "0") + pattern
        if let re = compiled[key] { return re }
        let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [.anchorsMatchLines] : [.caseInsensitive, .anchorsMatchLines])
        compiled[key] = re
        return re
    }

    /// Keeps the first letter's case: "In order to" → "To".
    static func matchCase(_ fix: String, like original: String) -> String {
        guard let o = original.first, let f = fix.first, o.isUppercase, f.isLowercase else { return fix }
        return f.uppercased() + fix.dropFirst()
    }

    /// Matches inside a link, an email address, inline code or a file path are left alone.
    private static func insideCodeOrLink(_ ns: NSString, _ r: NSRange) -> Bool {
        let line = ns.lineRange(for: r)
        let start = max(line.location, r.location - 60)
        let end = min(NSMaxRange(line), NSMaxRange(r) + 60)
        let around = ns.substring(with: NSRange(location: start, length: end - start))
        let tokenStart = ns.substring(with: NSRange(location: start, length: r.location - start)).split(separator: " ").last.map(String.init) ?? ""
        let tokenEnd = ns.substring(with: NSRange(location: NSMaxRange(r), length: end - NSMaxRange(r))).split(separator: " ").first.map(String.init) ?? ""
        let token = tokenStart + ns.substring(with: r) + tokenEnd
        if token.contains("://") || token.contains("@") || token.contains("www.") || token.contains("/") || token.contains("\\") { return true }
        return around.filter { $0 == "`" }.count >= 2
    }
}
