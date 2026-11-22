import CryptoKit
import Foundation

/// A GGUF model on Hugging Face that Inkwell can download and run.
struct LocalModel: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var vendor: String
    var license: String
    var repo: String
    var file: String
    var bytes: Int64
    var sha256: String?
    var minRAM: Int          // GB of memory the Mac should have
    var speed: Int           // 1...3
    var accuracy: Int        // 1...3
    var tagline: String
    var isCustom = false

    var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    var pageURL: URL { URL(string: "https://huggingface.co/\(repo)")! }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    /// Rough memory while running: the weights plus the context cache.
    var memoryText: String { ByteCountFormatter.string(fromByteCount: Int64(Double(bytes) * 1.1) + 500_000_000, countStyle: .memory) }

    static let catalog: [LocalModel] = [
        .init(id: "gemma4-e2b", name: "Gemma 4 E2B", vendor: "Google", license: "Apache 2.0",
              repo: "unsloth/gemma-4-E2B-it-GGUF", file: "gemma-4-E2B-it-Q4_K_M.gguf", bytes: 3_106_738_272,
              sha256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8",
              minRAM: 8, speed: 3, accuracy: 2, tagline: "Fast and accurate"),
        .init(id: "gemma4-e4b", name: "Gemma 4 E4B", vendor: "Google", license: "Apache 2.0",
              repo: "unsloth/gemma-4-E4B-it-GGUF", file: "gemma-4-E4B-it-Q4_K_M.gguf", bytes: 4_977_171_584,
              sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87",
              minRAM: 16, speed: 2, accuracy: 3, tagline: "Most accurate for its size"),
        .init(id: "gemma4-12b", name: "Gemma 4 12B", vendor: "Google", license: "Apache 2.0",
              repo: "unsloth/gemma-4-12b-it-GGUF", file: "gemma-4-12b-it-Q4_K_M.gguf", bytes: 7_121_861_440,
              sha256: "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42",
              minRAM: 32, speed: 1, accuracy: 3, tagline: "Best writing quality"),
        .init(id: "qwen35-4b", name: "Qwen 3.5 4B", vendor: "Alibaba", license: "Apache 2.0",
              repo: "unsloth/Qwen3.5-4B-GGUF", file: "Qwen3.5-4B-Q4_K_M.gguf", bytes: 2_740_937_888,
              sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
              minRAM: 8, speed: 2, accuracy: 2, tagline: "Careful, few wrong changes"),
        .init(id: "gemma3-4b", name: "Gemma 3 4B", vendor: "Google", license: "Gemma license",
              repo: "bartowski/google_gemma-3-4b-it-GGUF", file: "google_gemma-3-4b-it-Q4_K_M.gguf", bytes: 2_489_758_112,
              sha256: "4996030242583a40aa151ff93f49ed787ac8c25e4120c3ae4588b2e2a7d1ae94",
              minRAM: 8, speed: 2, accuracy: 2, tagline: "Previous Gemma, well tested"),
        .init(id: "llama31-8b", name: "Llama 3.1 8B", vendor: "Meta", license: "Llama 3.1 license",
              repo: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF", file: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf", bytes: 4_920_739_232,
              sha256: "7b064f5842bf9532c91456deda288a1b672397a54fa729aa665952863033557c",
              minRAM: 16, speed: 1, accuracy: 2, tagline: "Meta's Llama, strong rewrites"),
        .init(id: "llama32-3b", name: "Llama 3.2 3B", vendor: "Meta", license: "Llama 3.2 license",
              repo: "bartowski/Llama-3.2-3B-Instruct-GGUF", file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf", bytes: 2_019_377_696,
              sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
              minRAM: 8, speed: 3, accuracy: 1, tagline: "Light and quick"),
        .init(id: "llama32-1b", name: "Llama 3.2 1B", vendor: "Meta", license: "Llama 3.2 license",
              repo: "bartowski/Llama-3.2-1B-Instruct-GGUF", file: "Llama-3.2-1B-Instruct-Q4_K_M.gguf", bytes: 807_694_464,
              sha256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
              minRAM: 8, speed: 3, accuracy: 1, tagline: "Tiny, for older Macs"),
    ]
}

/// What this Mac has, for recommending a model.
enum MacInfo {
    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static var isAppleSilicon: Bool {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }

    /// The catalog model that fits this Mac best.
    static func recommendedID(memoryGB: Int = memoryGB) -> String {
        switch memoryGB {
        case 24...: "gemma4-e4b"
        case 12...: "gemma4-e2b"
        default: "qwen35-4b"
        }
    }
}

/// Downloads, verifies and deletes local models. Files live in ~/Library/Application Support/Inkwell/Models.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var installed = Set<String>()
    /// Download progress 0...1 by model id; a value of 1 means "verifying".
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]

    let dir: URL
    private var tasks: [String: Download] = [:]

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inkwell/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        refresh()
    }

    var allModels: [LocalModel] { LocalModel.catalog + AppSettings.shared.customModels }

    func model(_ id: String?) -> LocalModel? { allModels.first { $0.id == id } }
    func path(_ m: LocalModel) -> URL { dir.appendingPathComponent(m.file) }
    private func partial(_ m: LocalModel) -> URL { dir.appendingPathComponent(m.file + ".partial") }

    func refresh() {
        installed = Set(allModels.filter { FileManager.default.fileExists(atPath: path($0).path) }.map(\.id))
    }

    /// Bytes already downloaded of an unfinished download (it resumes from there).
    func partialBytes(_ m: LocalModel) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: partial(m).path)[.size] as? Int64) ?? 0
    }

    func download(_ m: LocalModel) {
        guard tasks[m.id] == nil, !installed.contains(m.id) else { return }
        errors[m.id] = nil
        progress[m.id] = Double(partialBytes(m)) / Double(max(m.bytes, 1))
        let d = Download(model: m, partial: partial(m), final: path(m)) { [weak self] p in
            Task { @MainActor in self?.progress[m.id] = p }
        } done: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.tasks[m.id] = nil
                self.progress[m.id] = nil
                if let error { self.errors[m.id] = error } else {
                    self.refresh()
                    // First model downloaded: start using it.
                    let s = AppSettings.shared
                    if s.localModelID == nil || self.model(s.localModelID).map({ !self.installed.contains($0.id) }) == true {
                        s.localModelID = m.id
                    }
                }
            }
        }
        tasks[m.id] = d
        d.start()
    }

    func cancel(_ m: LocalModel) {
        tasks[m.id]?.cancel()
        tasks[m.id] = nil
        progress[m.id] = nil
    }

    func delete(_ m: LocalModel) {
        cancel(m)
        if AppSettings.shared.localModelID == m.id { LlamaEngine.shared.unload() }
        try? FileManager.default.removeItem(at: path(m))
        try? FileManager.default.removeItem(at: partial(m))
        refresh()
    }

    /// Looks up the GGUF files in a Hugging Face repo ("owner/name" or a huggingface.co link).
    static func findGGUF(in input: String) async throws -> [LocalModel] {
        var repo = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: repo), u.host?.contains("huggingface.co") == true {
            repo = u.path.split(separator: "/").prefix(2).joined(separator: "/")
        }
        guard repo.split(separator: "/").count == 2 else { throw URLError(.badURL) }
        let api = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main")!
        let (data, resp) = try await URLSession.shared.data(from: api)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.fileDoesNotExist) }
        let ram = MacInfo.memoryGB
        return items.compactMap { item -> LocalModel? in
            guard let file = item["path"] as? String, file.hasSuffix(".gguf"), !file.lowercased().contains("mmproj"),
                  let size = (item["size"] as? NSNumber)?.int64Value else { return nil }
            let sha = (item["lfs"] as? [String: Any])?["oid"] as? String
            let gb = Double(size) / 1_073_741_824
            let need = gb < 3.5 ? 8 : gb < 7 ? 16 : gb < 14 ? 32 : 64
            return LocalModel(id: "hf:\(repo)/\(file)", name: file.replacingOccurrences(of: ".gguf", with: ""), vendor: repo.components(separatedBy: "/")[0],
                              license: "See model page", repo: repo, file: file, bytes: size, sha256: sha,
                              minRAM: need, speed: gb < 3 ? 3 : gb < 6 ? 2 : 1, accuracy: 0,
                              tagline: need <= ram ? "Fits your Mac" : "Needs \(need) GB+ memory", isCustom: true)
        }
        .sorted { a, b in
            // Q4_K_M first: the usual best size/quality balance.
            let qa = a.file.lowercased().contains("q4_k_m"), qb = b.file.lowercased().contains("q4_k_m")
            return qa != qb ? qa : a.bytes < b.bytes
        }
    }
}

/// One resumable download: streams into a .partial file, checks SHA-256, then moves it into place.
final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let model: LocalModel
    private let partial: URL
    private let final: URL
    private let onProgress: (Double) -> Void
    private let onDone: (String?) -> Void
    private var session: URLSession?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var lastReport = Date.distantPast
    private var cancelled = false

    init(model: LocalModel, partial: URL, final: URL, progress: @escaping (Double) -> Void, done: @escaping (String?) -> Void) {
        self.model = model; self.partial = partial; self.final = final
        self.onProgress = progress; self.onDone = done
    }

    func start() {
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        received = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        var req = URLRequest(url: model.url)
        if received > 0 { req.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.dataTask(with: req).resume()
    }

    func cancel() {
        cancelled = true
        session?.invalidateAndCancel()
        try? handle?.close()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else { completionHandler(.cancel); finish("Download failed (HTTP \(code)).") ; return }
        if code == 200 { received = 0; try? Data().write(to: partial) }   // server ignored the range: start over
        handle = try? FileHandle(forWritingTo: partial)
        _ = try? handle?.seekToEnd()
        completionHandler(handle == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        received += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.2 {
            lastReport = Date()
            onProgress(min(0.999, Double(received) / Double(max(model.bytes, 1))))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        session.finishTasksAndInvalidate()
        if cancelled { return }
        if let error { finish("Download stopped: \(error.localizedDescription) It will resume from where it left off."); return }
        onProgress(1)
        if let want = model.sha256?.lowercased(), Self.sha256(of: partial) != want {
            try? FileManager.default.removeItem(at: partial)
            finish("The downloaded file didn't match its checksum, so it was deleted. Please try again.")
            return
        }
        do {
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            finish(nil)
        } catch {
            finish("Couldn't save the model: \(error.localizedDescription)")
        }
    }

    private func finish(_ error: String?) { onDone(error) }

    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Local model as an LLMClient.
struct LocalClient: LLMClient {
    let model: LocalModel
    let path: String

    func complete(system: String, messages: [ChatMessage], jsonSchema: [String: Any]?, purpose: AIPurpose) async throws -> String {
        var system = system
        if jsonSchema != nil { system += "\n\nReply with only the JSON object." }
        let out = try await LlamaEngine.shared.complete(path: path, system: system, messages: messages,
                                                        grammar: jsonSchema.map(GBNF.from), maxTokens: purpose == .check ? 900 : 1200)
        // Strip any thinking block a model adds anyway.
        if let r = out.range(of: "</think>") { return String(out[r.upperBound...]) }
        return out
    }
}
