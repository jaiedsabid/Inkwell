import Foundation
import llama

/// Runs a downloaded GGUF model with the bundled llama.cpp. One model stays loaded; it's freed after a while unused.
final class LlamaEngine: @unchecked Sendable {
    static let shared = LlamaEngine()

    private let queue = DispatchQueue(label: "inkwell.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var loadedPath: String?
    private var idleTimer: DispatchSourceTimer?
    private let contextSize: UInt32 = 4096
    /// Free the model's memory after this long without a request.
    static let idleUnload: TimeInterval = 15 * 60

    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)   // llama.cpp is chatty on stderr
        llama_backend_init()
    }()

    enum EngineError: LocalizedError {
        case load(String), tooLong, decode, grammar
        var errorDescription: String? {
            switch self {
            case .load(let name): "Couldn't load the local model \(name). Try downloading it again."
            case .tooLong: "This text is too long for the local model. Select a shorter part."
            case .decode: "The local model stopped unexpectedly."
            case .grammar: "The local model couldn't produce the expected format."
            }
        }
    }

    var isLoaded: Bool { queue.sync { model != nil } }

    func complete(path: String, system: String, messages: [ChatMessage], grammar: String?, maxTokens: Int) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.run(path: path, system: system, messages: messages, grammar: grammar, maxTokens: maxTokens)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    func unload() { queue.async { self.unloadNow() } }

    /// Frees the model before the app exits (llama.cpp's Metal backend asserts if it's still loaded at exit).
    func shutdown() { queue.sync { self.unloadNow() } }

    // MARK: - Engine (on `queue`)

    private func run(path: String, system: String, messages: [ChatMessage], grammar: String?, maxTokens: Int) throws -> String {
        _ = Self.backend
        try load(path)
        guard let model, let ctx else { throw EngineError.load(URL(fileURLWithPath: path).lastPathComponent) }
        defer { scheduleUnload() }
        let vocab = llama_model_get_vocab(model)

        var tokens = tokenize(vocab, format(model: model, system: system, messages: messages))
        guard !tokens.isEmpty, tokens.count + maxTokens < Int(contextSize) else { throw EngineError.tooLong }
        llama_memory_clear(llama_get_memory(ctx), true)

        guard let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw EngineError.decode }
        defer { llama_sampler_free(smpl) }
        if let grammar {
            guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw EngineError.grammar }
            llama_sampler_chain_add(smpl, g)
            llama_sampler_chain_add(smpl, llama_sampler_init_greedy())   // checks want the most likely answer
        } else {
            llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.4))
            llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        }

        let rc = tokens.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
        guard rc == 0 else { throw EngineError.decode }

        var out: [UInt8] = []
        for _ in 0..<maxTokens {
            var tok = llama_sampler_sample(smpl, ctx, -1)   // also accepts the token into the sampler state
            if llama_vocab_is_eog(vocab, tok) { break }
            out += piece(vocab, tok)
            let r = withUnsafeMutablePointer(to: &tok) { llama_decode(ctx, llama_batch_get_one($0, 1)) }
            if r != 0 { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func load(_ path: String) throws {
        if loadedPath == path, model != nil, ctx != nil { idleTimer?.cancel(); return }
        unloadNow()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999                    // everything on the GPU (Metal)
        guard let m = llama_model_load_from_file(path, mp) else { throw EngineError.load(URL(fileURLWithPath: path).lastPathComponent) }
        var cp = llama_context_default_params()
        cp.n_ctx = contextSize
        cp.n_batch = contextSize
        let threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        cp.no_perf = true
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw EngineError.load(URL(fileURLWithPath: path).lastPathComponent)
        }
        model = m
        ctx = c
        loadedPath = path
    }

    private func unloadNow() {
        idleTimer?.cancel(); idleTimer = nil
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; loadedPath = nil
    }

    private func scheduleUnload() {
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.idleUnload)
        t.setEventHandler { [weak self] in self?.unloadNow() }
        t.resume()
        idleTimer = t
    }

    // MARK: - Text

    private func tokenize(_ vocab: OpaquePointer?, _ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let max = Int32(utf8.count + 16)
        var tokens = [llama_token](repeating: 0, count: Int(max))
        let n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, max, true, true)
        return n > 0 ? Array(tokens.prefix(Int(n))) : []
    }

    private func piece(_ vocab: OpaquePointer?, _ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        return n > 0 ? buf.prefix(Int(n)).map { UInt8(bitPattern: $0) } : []
    }

    /// Builds the prompt in the model's own chat format.
    private func format(model: OpaquePointer, system: String, messages: [ChatMessage]) -> String {
        let template = llama_model_chat_template(model, nil).map { String(cString: $0) } ?? ""
        let turns = [("system", system)] + messages.map { ($0.role == .user ? "user" : "assistant", $0.text) }
        return Self.format(template: template, turns: turns) { tmpl, turns in
            Self.applyBuiltIn(tmpl, turns)
        }
    }

    /// Formats `turns`. Gemma 4 is written out here (this llama.cpp doesn't know its format); everything else goes to
    /// llama.cpp's built-in templates, falling back to ChatML.
    static func format(template: String, turns: [(String, String)], builtIn: (String?, [(String, String)]) -> String?) -> String {
        if template.contains("<|turn>") {
            var s = ""
            for (role, text) in turns { s += "<|turn>\(role == "assistant" ? "model" : role)\n\(text)<turn|>\n" }
            return s + "<|turn>model\n"
        }
        var s = builtIn(template.isEmpty ? nil : template, turns) ?? builtIn("chatml", turns) ?? ""
        // Qwen 3 style models think out loud unless told not to; an empty think block skips it.
        if template.contains("<think>") { s += "<think>\n\n</think>\n\n" }
        return s
    }

    private static func applyBuiltIn(_ tmpl: String?, _ turns: [(String, String)]) -> String? {
        let cRoles = turns.map { strdup($0.0) }
        let cTexts = turns.map { strdup($0.1) }
        defer { (cRoles + cTexts).forEach { free($0) } }
        var msgs = zip(cRoles, cTexts).map { llama_chat_message(role: UnsafePointer($0.0), content: UnsafePointer($0.1)) }
        let size = turns.reduce(0) { $0 + $1.0.utf8.count + $1.1.utf8.count } * 2 + 1024
        var buf = [CChar](repeating: 0, count: size)
        func apply(_ t: UnsafePointer<CChar>?) -> Int32 {
            llama_chat_apply_template(t, &msgs, msgs.count, true, &buf, Int32(buf.count))
        }
        var n: Int32 = tmpl.map { $0.withCString { apply($0) } } ?? apply(nil)
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = tmpl.map { $0.withCString { apply($0) } } ?? apply(nil)
        }
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Turns the small JSON Schema subset Inkwell uses into a llama.cpp GBNF grammar, so local models can only answer with
/// valid JSON of the right shape. Properties follow the schema's "required" order.
enum GBNF {
    static func from(_ schema: [String: Any]) -> String {
        var rules: [String] = []
        func rule(_ s: [String: Any], _ name: String) -> String {
            let body: String
            switch s["type"] as? String {
            case "object":
                let props = s["properties"] as? [String: Any] ?? [:]
                let order = (s["required"] as? [String]) ?? props.keys.sorted()
                let parts = order.map { key in
                    "\"\\\"\(key)\\\"\" ws \":\" ws " + rule(props[key] as? [String: Any] ?? [:], name + "-" + key)
                }
                body = "\"{\" ws " + parts.joined(separator: " ws \",\" ws ") + " ws \"}\""
            case "array":
                let item = rule(s["items"] as? [String: Any] ?? [:], name + "-item")
                body = "\"[\" ws ( \(item) ( ws \",\" ws \(item) )* )? ws \"]\""
            case "integer":
                return "integer"
            default:
                guard let options = s["enum"] as? [String] else { return "string" }
                body = options.map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
            }
            rules.append("\(name) ::= \(body)")
            return name
        }
        _ = rule(schema, "root")
        rules.append(#"ws ::= | " " | "\n" [ \t]{0,20}"#)
        rules.append(#"string ::= "\"" ( [^"\\\x7F\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] ) )* "\"""#)
        rules.append(#"integer ::= "-"? [0-9]+"#)
        return rules.joined(separator: "\n")
    }
}
