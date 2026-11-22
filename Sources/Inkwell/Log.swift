import Foundation

/// Small diagnostic log at ~/Library/Logs/Inkwell.log. Records what Inkwell sees (app, field type, counts), never the text.
enum Log {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Inkwell.log")
    private static var last: [String: String] = [:]
    private static let queue = DispatchQueue(label: "inkwell.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    /// Writes `message` unless it's the same as the previous line with the same `key`.
    static func write(_ message: String, key: String = "main") {
        guard message != last[key] else { return }
        last[key] = message
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? Int ?? 0) > 2_000_000 { try? FileManager.default.removeItem(at: url) }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
