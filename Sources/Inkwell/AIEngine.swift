import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ChatMessage: Equatable {
    enum Role: String { case user, assistant }
    var role: Role
    var text: String
}

enum AIPurpose {
    case check, chat, complete
    /// Live checks and next-word suggestions use the fast model.
    var isFast: Bool { self != .chat }
}

enum AIError: LocalizedError {
    case noKey, noModel, noLocalModel, onDeviceUnavailable(String), http(Int, String), refused, badResponse, cancelled

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your API key in Settings → AI Engine."
        case .noLocalModel: "Download a local model in Settings → AI Engine."
        case .noModel: "Choose a model in Settings → AI Engine."
        case .onDeviceUnavailable(let why): "On-device AI isn't available: \(why)"
        case .http(let code, let msg): "The AI service returned an error (\(code)). \(msg)"
        case .refused: "The AI declined this request."
        case .badResponse: "The AI sent a reply Inkwell couldn't read."
        case .cancelled: "Cancelled."
        }
    }
}

protocol LLMClient {
    /// `jsonSchema` asks for a JSON object matching the schema; the raw JSON text is returned.
    func complete(system: String, messages: [ChatMessage], jsonSchema: [String: Any]?, purpose: AIPurpose) async throws -> String
}

// MARK: - Anthropic

struct AnthropicClient: LLMClient {
    let key: String
    let checkModel: String
    let chatModel: String

    func complete(system: String, messages: [ChatMessage], jsonSchema: [String: Any]?, purpose: AIPurpose) async throws -> String {
        let model = purpose.isFast ? checkModel : chatModel
        var body: [String: Any] = [
            "model": model,
            "max_tokens": purpose == .complete ? 300 : purpose.isFast ? 4000 : 8000,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        // Live checking must be fast: low effort. Rewrites get a little more thought.
        var output: [String: Any] = ["effort": purpose.isFast ? "low" : "medium"]
        if let schema = jsonSchema { output["format"] = ["type": "json_schema", "schema": schema] }
        body["output_config"] = output

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = purpose.isFast ? 30 : 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Opus / Sonnet: retry on a fallback model server-side if a safety classifier declines.
        if model.contains("opus") || model.contains("sonnet") || model.contains("fable") {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw AIError.http(status, msg)
        }
        if json["stop_reason"] as? String == "refusal" { throw AIError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }
}

// MARK: - OpenAI-compatible (OpenAI, OpenRouter, Ollama)

struct OpenAIClient: LLMClient {
    var baseURL = "https://api.openai.com/v1"
    var key: String?
    let checkModel: String
    let chatModel: String
    var extraHeaders: [String: String] = [:]
    var timeoutScale: Double = 1

    func complete(system: String, messages: [ChatMessage], jsonSchema: [String: Any]?, purpose: AIPurpose) async throws -> String {
        let model = purpose.isFast ? checkModel : chatModel
        guard !model.isEmpty else { throw AIError.noModel }
        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any] = ["model": model, "messages": msgs]
        guard let schema = jsonSchema else { return try await send(body, purpose) }

        // Strict schema first; some models/servers only take plain JSON mode, or none.
        body["response_format"] = ["type": "json_schema", "json_schema": ["name": "result", "schema": schema, "strict": true]]
        do { return try await send(body, purpose) } catch AIError.http(let code, _) where code == 400 || code == 422 {}
        body["response_format"] = ["type": "json_object"]
        do { return try await send(body, purpose) } catch AIError.http(let code, _) where code == 400 || code == 422 {}
        body["response_format"] = nil
        msgs[0]["content"] = system + "\n\nReply with only a JSON object."
        body["messages"] = msgs
        return try await send(body, purpose)
    }

    private func send(_ body: [String: Any], _ purpose: AIPurpose) async throws -> String {
        var req = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = (purpose.isFast ? 30 : 90) * timeoutScale
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json else {
            let err = json?["error"]
            let msg = ((err as? [String: Any])?["message"] as? String) ?? (err as? String) ?? ""
            throw AIError.http(status, msg)
        }
        let choice = (json["choices"] as? [[String: Any]])?.first
        guard let text = (choice?["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else { throw AIError.badResponse }
        return text
    }
}

// MARK: - Google Gemini

struct GeminiClient: LLMClient {
    let key: String
    let checkModel: String
    let chatModel: String

    func complete(system: String, messages: [ChatMessage], jsonSchema: [String: Any]?, purpose: AIPurpose) async throws -> String {
        let model = (purpose.isFast ? checkModel : chatModel).replacingOccurrences(of: "models/", with: "")
        var body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": messages.map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] },
        ]
        guard let schema = jsonSchema else { return try await send(model, body, purpose) }
        body["generationConfig"] = ["responseMimeType": "application/json", "responseJsonSchema": schema]
        do { return try await send(model, body, purpose) } catch AIError.http(400, _) {}
        // Older models don't take a schema: plain JSON mode.
        body["generationConfig"] = ["responseMimeType": "application/json"]
        return try await send(model, body, purpose)
    }

    private func send(_ model: String, _ body: [String: Any], _ purpose: AIPurpose) async throws -> String {
        let path = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(path):generateContent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = purpose.isFast ? 30 : 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw AIError.http(status, msg)
        }
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        if candidate?["finishReason"] as? String == "SAFETY" { throw AIError.refused }
        let parts = ((candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        // Skip "thought" parts some models include.
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }
}

// MARK: - Model lists

enum ModelLister {
    /// Models the provider offers, for the model pickers. Empty when it can't be reached.
    static func fetch(_ provider: Provider, key: String?, ollamaURL: String) async -> [String] {
        func get(_ url: String, headers: [String: String] = [:]) async -> [String: Any]? {
            guard let u = URL(string: url) else { return nil }
            var req = URLRequest(url: u)
            req.timeoutInterval = 10
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func ids(_ json: [String: Any]?) -> [String] { (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }

        switch provider {
        case .anthropic:
            guard let key else { return [] }
            return ids(await get("https://api.anthropic.com/v1/models?limit=100", headers: ["x-api-key": key, "anthropic-version": "2026-10-21"]))
        case .openai:
            guard let key else { return [] }
            let skip = ["embedding", "whisper", "tts", "dall-e", "image", "audio", "realtime", "moderation", "transcribe", "search"]
            return ids(await get("https://api.openai.com/v1/models", headers: ["authorization": "Bearer \(key)"]))
                .filter { id in !skip.contains { id.contains($0) } }.sorted()
        case .gemini:
            guard let key else { return [] }
            let json = await get("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200", headers: ["x-goog-api-key": key])
            return (json?["models"] as? [[String: Any]] ?? [])
                .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
                .filter { $0.hasPrefix("gemini") }
        case .openrouter:
            return ids(await get("https://openrouter.ai/api/v1/models")).sorted()
        case .ollama:
            let json = await get(ollamaURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/tags")
            return (json?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
    }
}

// MARK: - On-device (Apple Foundation Models, macOS 26+)

enum OnDevice {
    static var isSupportedOS: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// nil when ready, otherwise a short reason.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "this Mac doesn't support Apple Intelligence"
                case .appleIntelligenceNotEnabled: return "turn on Apple Intelligence in System Settings"
                case .modelNotReady: return "the model is still downloading"
                @unknown default: return "not available right now"
                }
            }
        }
        #endif
        return "needs macOS 26 or later"
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct OnDeviceClient: LLMClient {
    func complete(system: String, messages: [ChatMessage], jsonSchema: [String: Any]?, purpose: AIPurpose) async throws -> String {
        if let why = OnDevice.unavailableReason { throw AIError.onDeviceUnavailable(why) }
        var instructions = system
        if jsonSchema != nil {
            instructions += "\n\nReply with only a JSON object, no other text and no code fences."
        }
        let session = LanguageModelSession(instructions: instructions)
        // The session API is turn-based; replay earlier turns as one transcript prompt.
        var prompt = ""
        if messages.count > 1 {
            for m in messages.dropLast() {
                prompt += (m.role == .user ? "User: " : "You replied: ") + m.text + "\n\n"
            }
            prompt += "User: "
        }
        prompt += messages.last?.text ?? ""
        if let jsonSchema {
            // Guided generation: the framework makes the model produce exactly this shape.
            let schema = try GenerationSchema(root: Self.dynamic(jsonSchema, name: "Result"), dependencies: [])
            let response = try await session.respond(to: prompt, schema: schema)
            return response.content.jsonString
        }
        let response = try await session.respond(to: prompt)
        return response.content
    }

    /// Converts the small JSON Schema subset Inkwell uses (object, array, string with enum, integer) to a runtime schema.
    static func dynamic(_ s: [String: Any], name: String) -> DynamicGenerationSchema {
        switch s["type"] as? String {
        case "object":
            let props = s["properties"] as? [String: Any] ?? [:]
            let required = Set(s["required"] as? [String] ?? [])
            let list = props.keys.sorted().map { key in
                DynamicGenerationSchema.Property(name: key, schema: dynamic(props[key] as? [String: Any] ?? [:], name: name + "_" + key),
                                                 isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, properties: list)
        case "array":
            return DynamicGenerationSchema(arrayOf: dynamic(s["items"] as? [String: Any] ?? [:], name: name + "Item"))
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        default:
            if let options = s["enum"] as? [String] { return DynamicGenerationSchema(name: name, anyOf: options) }
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
#endif

// MARK: - Factory

@MainActor
enum AI {
    static func client() throws -> LLMClient {
        let s = AppSettings.shared
        switch s.engine {
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) { return OnDeviceClient() }
            #endif
            throw AIError.onDeviceUnavailable("needs macOS 26 or later")
        case .local:
            let store = ModelStore.shared
            guard let m = store.model(s.localModelID), store.installed.contains(m.id) else { throw AIError.noLocalModel }
            return LocalClient(model: m, path: store.path(m).path)
        case .cloud:
            if s.provider == .ollama {
                let base = s.ollamaURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1"
                // Local models can be slow to load the first time.
                return OpenAIClient(baseURL: base, key: nil, checkModel: s.checkModel, chatModel: s.chatModel, timeoutScale: 4)
            }
            guard let key = Keychain.get(s.provider) else { throw AIError.noKey }
            switch s.provider {
            case .anthropic: return AnthropicClient(key: key, checkModel: s.checkModel, chatModel: s.chatModel)
            case .openai: return OpenAIClient(key: key, checkModel: s.checkModel, chatModel: s.chatModel)
            case .gemini: return GeminiClient(key: key, checkModel: s.checkModel, chatModel: s.chatModel)
            case .openrouter:
                return OpenAIClient(baseURL: "https://openrouter.ai/api/v1", key: key, checkModel: s.checkModel, chatModel: s.chatModel,
                                    extraHeaders: ["X-Title": "Inkwell"])
            case .ollama: throw AIError.noKey   // handled above
            }
        }
    }

    static var isConfigured: Bool {
        let s = AppSettings.shared
        switch s.engine {
        case .onDevice: return OnDevice.unavailableReason == nil
        case .local: return ModelStore.shared.model(s.localModelID).map { ModelStore.shared.installed.contains($0.id) } ?? false
        case .cloud: return s.provider.needsKey ? Keychain.get(s.provider) != nil : !s.checkModel.isEmpty
        }
    }
}

/// Pulls the JSON object out of a reply that may have extra text around it (on-device replies sometimes do).
func extractJSONObject(_ text: String) -> Data? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
    return String(text[start...end]).data(using: .utf8)
}
