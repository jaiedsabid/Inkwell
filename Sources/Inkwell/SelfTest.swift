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
        check(parsed?[2]?.count == 1, "drops unlocatable issue")
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

        // Spelling
        let sp = TextTools.spelling("This is teh best exmaple of it.", language: "en", ignored: [])
        check(sp.contains { $0.original == "teh" }, "spell checker flags 'teh'")
        check(TextTools.isSkippable("API") && TextTools.isSkippable("user@x.com") && !TextTools.isSkippable("hello"), "skips acronyms and addresses")

        print(failures == 0 ? "All passed" : "\(failures) failed")
        return failures == 0
    }
}
