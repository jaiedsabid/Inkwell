import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct ChatMessage: Equatable {
    enum Role: String { case user, assistant }
    var role: Role
    var text: String
}

enum AIPurpose { case check, chat }

enum AIError: LocalizedError {
    case noKey, onDeviceUnavailable(String), http(Int, String), refused, badResponse, cancelled

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your API key in Settings → AI Engine."
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
        let model = purpose == .check ? checkModel : chatModel
        var body: [String: Any] = [
            "model": model,
            "max_tokens": purpose == .check ? 4000 : 8000,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        // Live checking must be fast: low effort. Rewrites get a little more thought.
        var output: [String: Any] = ["effort": purpose == .check ? "low" : "medium"]
        if let schema = jsonSchema { output["format"] = ["type": "json_schema", "schema": schema] }
        body["output_config"] = output

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = purpose == .check ? 30 : 90
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

// MARK: - OpenAI

struct OpenAIClient: LLMClient {
    let key: String
    let checkModel: String
    let chatModel: String

    func complete(system: String, messages: [ChatMessage], jsonSchema: [String: Any]?, purpose: AIPurpose) async throws -> String {
        var msgs: [[String: Any]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any] = ["model": purpose == .check ? checkModel : chatModel, "messages": msgs]
        if let schema = jsonSchema {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "result", "schema": schema, "strict": true]]
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = purpose == .check ? 30 : 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw AIError.http(status, msg)
        }
        let choice = (json["choices"] as? [[String: Any]])?.first
        guard let text = (choice?["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else { throw AIError.badResponse }
        return text
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
        let response = try await session.respond(to: prompt)
        return response.content
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
        case .cloud:
            guard let key = Keychain.get(s.provider) else { throw AIError.noKey }
            switch s.provider {
            case .anthropic: return AnthropicClient(key: key, checkModel: s.checkModel, chatModel: s.chatModel)
            case .openai: return OpenAIClient(key: key, checkModel: s.checkModel, chatModel: s.chatModel)
            }
        }
    }

    static var isConfigured: Bool {
        let s = AppSettings.shared
        switch s.engine {
        case .onDevice: return OnDevice.unavailableReason == nil
        case .cloud: return Keychain.get(s.provider) != nil
        }
    }
}

/// Pulls the JSON object out of a reply that may have extra text around it (on-device replies sometimes do).
func extractJSONObject(_ text: String) -> Data? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
    return String(text[start...end]).data(using: .utf8)
}
