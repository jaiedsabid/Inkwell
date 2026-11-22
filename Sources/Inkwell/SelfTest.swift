import Foundation

/// `Inkwell --selftest`: checks the parts that don't need a UI or a network (text splitting, reply parsing, spelling).
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String) {
        print(ok ? "  ok   \(name)" : "  FAIL \(name)")
        if !ok { failures += 1 }
    }

    static func run() -> Bool {
        print("Inkwell self-test")
        failures = 0

        // Sentences
        let text = "I has a apple.  This are good! Visit https://example.com today?\nNew line here."
        let s = TextTools.sentences(text)
        check(s.count == 4, "splits into 4 sentences (got \(s.count))")
        check(s.first?.text == "I has a apple.", "first sentence trimmed")
        if s.count > 1 {
            check((text as NSString).substring(with: s[1].range) == "This are good!", "sentence range maps back into text")
        }

        // Locate
        check(TextTools.locate("has", in: "I has a apple.") == NSRange(location: 2, length: 3), "locates exact span")
        check(TextTools.locate("I HAS", in: "I has a apple.") != nil, "locates ignoring case")
        check(TextTools.locate("nope", in: "I has a apple.") == nil, "missing span is nil")

        // Reply parsing
        let reply = """
        {"issues":[
          {"sentence":1,"kind":"grammar","original":"has","replacement":"have","explanation":"Use 'have' with 'I'."},
          {"sentence":1,"kind":"grammar","original":"a apple","replacement":"an apple","explanation":"Use 'an' before a vowel sound."},
          {"sentence":2,"kind":"clarity","original":"This are good!","replacement":"This is good!","explanation":"Clearer."},
          {"sentence":2,"kind":"grammar","original":"not in sentence","replacement":"x","explanation":""},
          {"sentence":9,"kind":"grammar","original":"a","replacement":"b","explanation":""},
          {"sentence":1,"kind":"grammar","original":"I","replacement":"I","explanation":"no-op"}
        ]}
        """
        let parsed = CheckPrompt.parse("Here you go: " + reply, sentences: [1: "I has a apple.", 2: "This are good!", 3: "Fine."])
        check(parsed != nil, "parses reply with extra text around JSON")
        check(parsed?[1]?.count == 2, "keeps 2 issues for sentence 1")
        check(parsed?[1]?.first?.location == 2, "issue located at right offset")
        check(parsed?[2]?.count == 1 && parsed?[2]?.first?.kind == .grammar, "drops unlocatable issue; one-word form fix becomes grammar")
        check(parsed?[3]?.isEmpty == true, "clean sentence cached as empty")
        check(parsed?[9] == nil, "ignores unknown sentence id")
        check(CheckPrompt.parse("not json", sentences: [1: "x"]) == nil, "bad reply is nil")

        // Prompt content
        let sys = CheckPrompt.system(.init(languageName: "English (US)", tone: .professional, strictness: .picky, toneCheck: false))
        check(sys.contains("Professional") && sys.contains("Never use the kind \"tone\""), "system prompt includes tone and kinds")
        check(CheckPrompt.user([(1, "Hi \"there\"")]).contains("\\\"there\\\""), "user payload is escaped JSON")

        // Chat prompt
        let turns = [ChatModel.Turn(prompt: "shorter", result: "Short."), ChatModel.Turn(prompt: "friendlier")]
        let msgs = ChatPrompt.messages(source: "A long sentence.", turns: turns)
        check(msgs.count == 3 && msgs[1].role == .assistant && msgs[2].text == "friendlier", "chat history replays refinements")
        check(ChatPrompt.clean("\"Hello there.\"") == "Hello there.", "strips wrapping quotes")
        check(ChatPrompt.clean("She said \"hi\" to me.") == "She said \"hi\" to me.", "keeps inner quotes")
        check(ChatPrompt.clean("Here is the revised text:\n\n\"Please send it.\"") == "Please send it.", "drops intro line and quotes")
        check(ChatPrompt.clean("Note: send it today.\nThanks") == "Note: send it today.\nThanks", "keeps a real first line")
        let g = GBNF.from(CheckPrompt.schema)
        if CommandLine.arguments.contains("--print-grammar") { print(g) }
        check(g.contains("root ::= \"{\" ws \"\\\"issues\\\"\"") && g.contains("\"\\\"spelling\\\"\" | ") && g.contains("string ::="), "JSON grammar built from schema")
        let g4 = LlamaEngine.format(template: "{{ '<|turn>user' }}", turns: [("system", "S"), ("user", "U")]) { _, _ in nil }
        check(g4 == "<|turn>system\nS<turn|>\n<|turn>user\nU<turn|>\n<|turn>model\n", "Gemma 4 prompt format")
        check(MacInfo.recommendedID(memoryGB: 8) == "qwen35-4b" && MacInfo.recommendedID(memoryGB: 16) == "gemma4-e2b" && MacInfo.recommendedID(memoryGB: 36) == "gemma4-e4b", "model recommendation by memory")

        // Phase 2: dictionary, strictness, quick actions, site matching
        let sys2 = CheckPrompt.system(.init(languageName: "English (US)", tone: .casual, strictness: .relaxed, toneCheck: false, dictionary: ["Inkwell", "Jaied"]))
        check(sys2.contains("Inkwell, Jaied") && sys2.contains("Only flag definite"), "prompt carries dictionary and strictness")
        let qa = ChatPrompt.messages(source: "Hi.", turns: [ChatModel.Turn(prompt: "Shorter", instruction: "Make it shorter.")])
        check(qa.first?.text.hasSuffix("Instruction: Make it shorter.") == true, "quick action sends its instruction")
        let s0 = AppSettings.shared
        let savedSites = s0.disabledSites
        s0.disabledSites = ["google.com"]
        check(s0.isDisabled(app: nil, host: "docs.google.com") && !s0.isDisabled(app: nil, host: "notgoogle.com"), "site rule covers subdomains only")
        s0.disabledSites = savedSites
        check(s0.isDisabled(app: "com.apple.Terminal", host: nil) || !s0.disabledApps.contains("com.apple.Terminal"), "disabled app rule")

        // Spelling
        let sp = TextTools.spelling("This is teh best exmaple of it.", language: "en", ignored: [])
        check(sp.contains { $0.original == "teh" }, "spell checker flags 'teh'")
        let sp2 = TextTools.spelling("This is teh best exmaple of it.", language: "en", ignored: ["teh"])
        check(!sp2.contains { $0.original == "teh" }, "dictionary words are not flagged")
        check(TextTools.isSkippable("API") && TextTools.isSkippable("user@x.com") && !TextTools.isSkippable("hello"), "skips acronyms and addresses")

        // Local punctuation rules
        let pt = "can you send me the report by tomorrow\nThanks for the help today. we should meet again soon"
        let pis = TextTools.punctuation(TextTools.sentences(pt), skip: { _ in false })
        check(pis.contains { $0.original == "tomorrow" && $0.replacement == "tomorrow?" }, "question gets a question mark")
        check(pis.contains { $0.original == "soon" && $0.replacement == "soon." }, "missing full stop is flagged")
        check(pis.contains { $0.original == "can" && $0.replacement == "Can" } && pis.contains { $0.original == "we" && $0.replacement == "We" }, "lowercase sentence start is flagged")
        check(!pis.contains { $0.original == "today." }, "finished sentence is left alone")
        let listItems = TextTools.punctuation(TextTools.sentences("- buy milk and eggs today\n1. call the bank about it"), skip: { _ in false })
        check(!listItems.contains { $0.replacement.hasSuffix(".") }, "list items don't need a full stop")
        check(TextTools.punctuation(TextTools.sentences("I bought a new iPhone"), skip: { _ in false }).allSatisfy { $0.original != "iPhone" || $0.replacement == "iPhone." }, "brand casing untouched")

        check(pis.first { $0.original == "soon" }?.kind == .punctuation && pis.first { $0.original == "we" }?.kind == .capitalization, "punctuation and capitalization have their own type")
        check(CheckPrompt.system(.init(languageName: "English", tone: .natural, strictness: .standard, toneCheck: false)).contains("\"punctuation\":"), "prompt explains punctuation type")

        // Next-word suggestions
        check(Autocomplete.clean("\"quick brown fox\"\nmore", after: "The ", length: .phrase) == "quick brown fox", "suggestion: strips quotes and extra lines")
        check(Autocomplete.clean(" for your help", after: "Thanks ", length: .phrase) == "for your help", "suggestion: no double space")
        check(Autocomplete.clean("See you soon", after: "Thanks.", length: .phrase) == " See you soon", "suggestion: space after punctuation")
        check(Autocomplete.clean("s for the help", after: "Thank", length: .phrase) == "s for the help", "suggestion: finishes a word")
        check(Autocomplete.clean("file organization", after: "help with the", length: .phrase) == " file organization", "suggestion: adds missing space")
        check(Autocomplete.clean("model.", after: "AI m", length: .phrase) == "odel.", "suggestion: whole word sent for a half-typed word")
        check(Autocomplete.clean(" model", after: "AI m", length: .phrase) == "odel", "suggestion: whole word with a space")
        check(Autocomplete.clean("Update", after: "Thanks for the upd", length: .phrase) == "ate", "suggestion: whole word, other case")
        check(Autocomplete.clean(" amazing", after: "I am", length: .phrase) == " amazing", "suggestion: next word that starts like the last one")
        check(Autocomplete.clean("odel for text", after: "AI m", length: .phrase) == "odel for text", "suggestion: correct rest of word untouched")
        check(Autocomplete.clean("I wanted to say thanks", after: "I wanted to say", length: .phrase) == " thanks", "suggestion: drops repeated text")
        check(Autocomplete.clean("   ", after: "Hello there", length: .phrase).isEmpty, "suggestion: blank reply is nothing")
        check(Autocomplete.firstWord(of: " quick brown") == " quick" && Autocomplete.firstWord(of: "s, then") == "s,", "suggestion: first word")
        check(Autocomplete.worthSuggesting("Hello, I am writing") && !Autocomplete.worthSuggesting("Hi") && !Autocomplete.worthSuggesting("Some text here\n"), "suggestion: when to suggest")
        check(!Autocomplete.worthSuggesting("That went well. ") && !Autocomplete.worthSuggesting("That went well. We"), "suggestion: not at a new sentence")
        check(Autocomplete.worthSuggesting("That went well. We should") && Autocomplete.worthSuggesting("Thanks for the upd"), "suggestion: mid-sentence and mid-word")
        check(Autocomplete.pick(#"{"completion":" questions.","confidence":5}"#, after: "Let me know if you have any", length: .phrase) == " questions.", "suggestion: confident reply kept")
        check(Autocomplete.pick(#"{"completion":" the report","confidence":2}"#, after: "Please send me", length: .phrase).isEmpty, "suggestion: unsure reply dropped")
        check(Autocomplete.pick(#"{"completion":" review of the document.","confidence":4}"#, after: "Thanks for your help with the", length: .phrase).isEmpty
              && Autocomplete.pick(#"{"completion":" hearing from you.","confidence":4}"#, after: "Looking forward to", length: .phrase) == " hearing from you.", "suggestion: long guesses need high confidence")
        check(!Autocomplete.isGrounded(" on March 14", in: "Let's meet") && !Autocomplete.isGrounded(" with Sarah", in: "I spoke"), "suggestion: invented dates and names dropped")
        check(Autocomplete.isGrounded(" with Sarah tomorrow", in: "Sarah said she'd call. I'll meet") && Autocomplete.isGrounded(" questions.", in: "Any"), "suggestion: grounded text kept")
        // Card text
        let ci = Checker.addContext(Issue(range: NSRange(location: 2, length: 3), kind: .grammar, original: "has", replacement: "have", explanation: ""), in: "I has a apple and it are red." as NSString)
        check(ci.before == "I " && ci.after.hasPrefix(" a apple"), "card: words around the issue")
        let segs = WordDiff.segments(from: "The meeting that we had was long.", to: "Our meeting was long.")
        check(segs.first?.kind == .removed && segs.contains { $0.kind == .added && $0.text == "Our" } && segs.last?.text == "was long.", "card: rewrite diff")
        check(CheckPrompt.parse(#"{"issues":[{"sentence":1,"kind":"clarity","original":"Thanks for your help.","replacement":"Thanks for your assistance.","explanation":"x"}]}"#, sentences: [1: "Thanks for your help."])?[1]?.isEmpty == true, "synonym swap dropped")

        // Custom tones
        let old = try? JSONDecoder().decode(Tone.self, from: Data("\"professional\"".utf8))
        check(old == .professional && old?.label == "Professional", "tones saved before custom tones still load")
        let savedCustom = ToneRegistry.custom
        ToneRegistry.custom = [CustomTone(id: "custom-test", name: "Pirate", guidance: "Talk like a pirate.", symbol: "flame")]
        let pirate = Tone(id: "custom-test")
        check(pirate.label == "Pirate" && pirate.guidance == "Talk like a pirate." && Tone.allCases.contains(pirate), "custom tone resolves name and guidance")
        check(CheckPrompt.system(.init(languageName: "English", tone: pirate, strictness: .standard, toneCheck: false)).contains("Pirate. Talk like a pirate."), "custom tone reaches the prompt")
        check((try? JSONEncoder().encode(pirate)).map { String(decoding: $0, as: UTF8.self) } == "\"custom-test\"", "tone encodes as its id")
        ToneRegistry.custom = []
        check(!pirate.exists && pirate.label == "Natural", "deleted custom tone falls back to Natural")
        ToneRegistry.custom = savedCustom

        // Word diff: whole-sentence "grammar" fixes become word fixes, big rewrites become clarity
        let ch = WordDiff.changes(from: "I has a apple and it are red.", to: "I have an apple and it is red.")
        check(ch.map(\.original) == ["has a", "are"] && ch.map(\.replacement) == ["have an", "is"], "word diff finds changed words (got \(ch.map(\.original)))")
        let split = CheckPrompt.parse(#"{"issues":[{"sentence":1,"kind":"grammar","original":"I has a apple and it are red.","replacement":"I have an apple and it is red.","explanation":"x"}]}"#, sentences: [1: "I has a apple and it are red."])
        check(split?[1]?.count == 2 && split?[1]?.first?.original == "has a" && split?[1]?.first?.location == 2, "long grammar fix is split into word fixes")
        let big = CheckPrompt.parse(#"{"issues":[{"sentence":1,"kind":"grammar","original":"The meeting that we had was a meeting where things were discussed by us.","replacement":"We discussed several things in the meeting.","explanation":"x"}]}"#, sentences: [1: "The meeting that we had was a meeting where things were discussed by us."])
        check(big?[1]?.count == 1 && big?[1]?.first?.kind == .clarity, "big rewrite becomes a clarity suggestion")

        // Phase 3: tone check prompt, stats
        let sys3 = CheckPrompt.system(.init(languageName: "English (US)", tone: .friendly, strictness: .standard, toneCheck: true))
        check(sys3.contains("\"tone\": the sentence doesn't fit") && !sys3.contains("Never use the kind"), "tone check adds the tone kind")
        check(Stats.wordCount("Hello, big world!") == 3 && Stats.wordCount("") == 0, "word count")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-selftest-\(UUID().uuidString).json")
        let st = Stats(file: tmp)
        if AppSettings.shared.collectStats {
            st.wordsWritten(12, app: "Notes")
            st.fixed(Issue(range: NSRange(location: 0, length: 3), kind: .spelling, original: "teh", replacement: "the", explanation: ""))
            st.found(.spelling); st.found(.grammar)
            let sum = st.summary(.day)
            check(sum.total.words == 12 && sum.total.apps["Notes"] == 12, "stats count words by app")
            check(sum.topMistakes.first?.0 == "teh → the", "stats keep common mistakes")
            check(sum.acceptRate == 0.5, "accept rate")
            check(st.summary(.month).perDay.count == 30 && st.summary(.week).perDay.last?.stats.words == 12, "week/month ranges end today")
            st.save()
            check(Stats(file: tmp).summary(.day).total.words == 12, "stats persist to disk")
        }
        try? FileManager.default.removeItem(at: tmp)
        let replyMsgs = ChatPrompt.messages(source: "Can you join Friday?", turns: [ChatModel.Turn(prompt: "Draft a reply", instruction: QuickAction.reply.instruction, isReply: true)])
        check(replyMsgs.first?.text.contains("message I received") == true, "reply helper prompt")

        print(failures == 0 ? "All passed" : "\(failures) failed")
        return failures == 0
    }

    /// `Inkwell --aitest`: runs one real check with the configured engine and prints what comes back.
    static func aiTest() async -> Bool {
        let sentences = [1: "I has a apple and it are red.", 2: "The meeting that we had was a meeting where things were discussed by us.", 3: "Thanks for your help."]
        print("Engine: \(AppSettings.shared.engine.rawValue)")
        do {
            let client = try AI.client()
            let opts = CheckPrompt.Options(languageName: "English (US)", tone: .professional, strictness: .standard, toneCheck: true)
            let start = Date()
            let raw = try await client.complete(system: CheckPrompt.system(opts), messages: [.init(role: .user, text: CheckPrompt.user(sentences.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))],
                                                jsonSchema: CheckPrompt.schema, purpose: .check)
            print(String(format: "Reply in %.1fs", Date().timeIntervalSince(start)))
            guard let parsed = CheckPrompt.parse(raw, sentences: sentences) else { print("Unreadable reply:\n\(raw)"); return false }
            for (id, list) in parsed.sorted(by: { $0.key < $1.key }) {
                for i in list { print("  [\(id)] \(i.kind.rawValue): \"\(i.original)\" → \"\(i.replacement)\" (\(i.explanation))") }
            }
            return true
        } catch {
            print("Failed: \(error.localizedDescription)")
            return false
        }
    }

    /// `Inkwell --localtest MODEL_ID`: downloads a catalog model if needed, then runs a check and a rewrite with it.
    static func localTest(_ id: String) async -> Bool {
        let store = ModelStore.shared
        guard let m = store.model(id) else { print("Unknown model \(id)"); return false }
        if !store.installed.contains(id) {
            print("Downloading \(m.name) (\(m.sizeText))…")
            store.download(m)
            var last = -1
            while store.progress[id] != nil {
                let p = Int((store.progress[id] ?? 0) * 100)
                if p / 10 != last / 10 { print("  \(p)%"); last = p }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if let e = store.errors[id] { print("Download failed: \(e)"); return false }
        }
        let client = LocalClient(model: m, path: store.path(m).path)
        let sentences = [1: "I has a apple and it are red.", 2: "The meeting that we had was a meeting where things were discussed by us.", 3: "Thanks for your help."]
        do {
            var t = Date()
            let opts = CheckPrompt.Options(languageName: "English (US)", tone: .professional, strictness: .standard, toneCheck: false)
            let raw = try await client.complete(system: CheckPrompt.system(opts),
                                                messages: [.init(role: .user, text: CheckPrompt.user(sentences.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))],
                                                jsonSchema: CheckPrompt.schema, purpose: .check)
            print(String(format: "Check (incl. loading) %.1fs", Date().timeIntervalSince(t)))
            guard let parsed = CheckPrompt.parse(raw, sentences: sentences) else { print("Unreadable:\n\(raw)"); return false }
            for (sid, list) in parsed.sorted(by: { $0.key < $1.key }) {
                for i in list { print("  [\(sid)] \(i.kind.rawValue): \"\(i.original)\" → \"\(i.replacement)\"") }
            }
            t = Date()
            let chat = try await client.complete(system: ChatPrompt.system(tone: .professional, language: "English (US)", writeMode: false),
                                                 messages: ChatPrompt.messages(source: "hey can u send me the report by tmrw its urgent", turns: [.init(prompt: "make it professional")]),
                                                 jsonSchema: nil, purpose: .chat)
            print(String(format: "Rewrite %.1fs: %@", Date().timeIntervalSince(t), ChatPrompt.clean(chat)))
            let samples = ["Thanks so much for your help with the", "I'm writing to let you know that the meeting", "Could you please send me",
                           "Let me know if you have any", "Hope you're doing", "The results of the experiment suggest that", "Sorry for the late", "We are building a new AI m", "Thanks for the upd"]
            for before in samples {
                t = Date()
                let ctx = Autocomplete.Context(app: "Mail", window: "Re: Project update", field: "Message body")
                let raw = try await client.complete(system: Autocomplete.prompt(length: .phrase, tone: .natural, language: "English (US)", context: ctx),
                                                    messages: [.init(role: .user, text: "Text before the cursor:\n<<<\n\(before)\n>>>")],
                                                    jsonSchema: Autocomplete.schema, purpose: .complete)
                let picked = Autocomplete.pick(raw, after: before, length: .phrase)
                print(String(format: "Suggest %.1fs: %@[%@]  (raw %@)", Date().timeIntervalSince(t), before, picked, raw.replacingOccurrences(of: "\n", with: " ")))
            }
            return true
        } catch {
            print("Failed: \(error.localizedDescription)")
            return false
        }
    }
}
