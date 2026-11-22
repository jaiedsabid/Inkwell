import Foundation

/// Counts for one day. Stored on this Mac only.
struct DayStats: Codable, Equatable {
    var words = 0                       // words written while Inkwell was on
    var found: [String: Int] = [:]      // suggestions shown, by IssueKind
    var fixed: [String: Int] = [:]      // suggestions accepted, by IssueKind
    var dismissed = 0
    var rewrites = 0                    // chat results accepted
    var mistakes: [String: Int] = [:]   // "original → fix" for accepted spelling/grammar fixes
    var apps: [String: Int] = [:]       // words by app name

    var fixedTotal: Int { fixed.values.reduce(0, +) }
    var foundTotal: Int { found.values.reduce(0, +) }

    mutating func add(_ o: DayStats) {
        words += o.words; dismissed += o.dismissed; rewrites += o.rewrites
        found.merge(o.found, uniquingKeysWith: +)
        fixed.merge(o.fixed, uniquingKeysWith: +)
        mistakes.merge(o.mistakes, uniquingKeysWith: +)
        apps.merge(o.apps, uniquingKeysWith: +)
    }
}

enum StatsRange: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String { switch self { case .day: "Today"; case .week: "7 days"; case .month: "30 days" } }
    var days: Int { switch self { case .day: 1; case .week: 7; case .month: 30 } }
}

struct StatsSummary {
    var total = DayStats()
    var previous = DayStats()            // the same length of time just before, for the trend
    var perDay: [(date: Date, stats: DayStats)] = []
    var acceptRate: Double? { total.foundTotal > 0 ? Double(total.fixedTotal) / Double(total.foundTotal) : nil }
    var topMistakes: [(String, Int)] { Array(total.mistakes.sorted { $0.value > $1.value }.prefix(5)) }
    var topApps: [(String, Int)] { Array(total.apps.sorted { $0.value > $1.value }.prefix(5)) }
}

@MainActor
final class Stats: ObservableObject {
    static let shared = Stats()

    @Published private(set) var days: [String: DayStats] = [:]
    private var saveWork: DispatchWorkItem?
    private let url: URL

    private static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(file: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inkwell")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = file ?? dir.appendingPathComponent("stats.json")
        if let data = try? Data(contentsOf: url), let d = try? JSONDecoder().decode([String: DayStats].self, from: data) { days = d }
    }

    static func key(_ date: Date) -> String { keyFormat.string(from: date) }

    // MARK: Recording

    private func record(_ change: (inout DayStats) -> Void) {
        guard AppSettings.shared.collectStats else { return }
        change(&days[Self.key(Date()), default: DayStats()])
        scheduleSave()
    }

    func wordsWritten(_ n: Int, app: String?) {
        guard n > 0 else { return }
        record { d in
            d.words += n
            if let app { d.apps[app, default: 0] += n }
        }
    }

    func found(_ kind: IssueKind) { record { $0.found[kind.rawValue, default: 0] += 1 } }

    func fixed(_ issue: Issue) {
        record { d in
            d.fixed[issue.kind.rawValue, default: 0] += 1
            if !issue.kind.isSentenceLevel, issue.original.count <= 40 {
                d.mistakes["\(issue.original) → \(issue.replacement)", default: 0] += 1
            }
        }
    }

    func dismissed() { record { $0.dismissed += 1 } }
    func rewrite() { record { $0.rewrites += 1 } }

    /// Shows the given numbers without saving them (snapshots).
    func preview(_ d: [String: DayStats]) { days = d }

    func reset() {
        days = [:]
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    func save() {
        // Keep about a year.
        if days.count > 400, let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: Date()) {
            let k = Self.key(cutoff)
            days = days.filter { $0.key >= k }
        }
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Reading

    func summary(_ range: StatsRange, now: Date = Date()) -> StatsSummary {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var s = StatsSummary()
        for i in stride(from: range.days - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let d = days[Self.key(date)] ?? DayStats()
            s.perDay.append((date, d))
            s.total.add(d)
        }
        for i in range.days..<(range.days * 2) {
            guard let date = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            if let d = days[Self.key(date)] { s.previous.add(d) }
        }
        return s
    }

    /// Splits a text into words the same way everywhere.
    nonisolated static func wordCount(_ text: String) -> Int {
        var n = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }
}
