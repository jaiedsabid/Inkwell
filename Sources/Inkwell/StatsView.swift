import Charts
import SwiftUI

struct StatsPane: View {
    @ObservedObject var stats = Stats.shared
    @ObservedObject var settings = AppSettings.shared
    @Loc private var range: StatsRange = .week
    @Loc private var hovered: Date?
    @Loc private var confirmReset = false

    var body: some View {
        let s = stats.summary(range)
        Form {
            Section {
                Picker("Period", selection: $range) {
                    ForEach(StatsRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                HStack(spacing: 10) {
                    StatTile(title: "Words written", value: s.total.words, previous: s.previous.words, range: range)
                    StatTile(title: "Fixes accepted", value: s.total.fixedTotal, previous: s.previous.fixedTotal, range: range)
                    StatTile(title: "Rewrites", value: s.total.rewrites, previous: s.previous.rewrites, range: range)
                }
                .padding(.vertical, 4)
            }

            if range != .day {
                Section("Words written per day") {
                    wordsChart(s)
                }
            }

            Section("Fixes by type") {
                let kinds = IssueKind.allCases.filter { $0 != .tone || settings.toneCheck }
                let maxCount = max(kinds.map { s.total.fixed[$0.rawValue] ?? 0 }.max() ?? 0, 1)
                ForEach(kinds, id: \.self) { kind in
                    let n = s.total.fixed[kind.rawValue] ?? 0
                    HStack(spacing: 10) {
                        Text(kind.label).frame(width: 70, alignment: .leading)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: kind.color))
                                .frame(width: max(n > 0 ? 6 : 0, g.size.width * CGFloat(n) / CGFloat(maxCount)))
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 10)
                        Text("\(n)").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
                if let rate = s.acceptRate {
                    LabeledContent("Suggestions you accepted", value: rate.formatted(.percent.precision(.fractionLength(0))))
                }
            }

            Section("Your most common mistakes") {
                if s.topMistakes.isEmpty {
                    Text("Nothing yet. Fixes you accept show up here.").foregroundStyle(.secondary)
                }
                ForEach(s.topMistakes, id: \.0) { m in
                    LabeledContent(m.0, value: "\(m.1)×")
                }
            }

            Section("Where you write") {
                if s.topApps.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(s.topApps, id: \.0) { a in
                    LabeledContent(a.0, value: "\(a.1.formatted()) words")
                }
            }

            Section {
                Toggle(isOn: $settings.collectStats) {
                    Text("Keep writing stats")
                    Text("Counts only, stored on this Mac. Your text is never saved.")
                }
                Button("Reset stats…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Delete all writing stats?", isPresented: $confirmReset) {
                        Button("Delete stats", role: .destructive) { stats.reset() }
                    } message: { Text("This can't be undone.") }
            }
        }
    }

    private func wordsChart(_ s: StatsSummary) -> some View {
        let unit: Calendar.Component = .day
        return Chart {
            ForEach(s.perDay, id: \.date) { day in
                BarMark(x: .value("Day", day.date, unit: unit), y: .value("Words", day.stats.words), width: .ratio(0.6))
                    .foregroundStyle(Theme.accent.opacity(hovered == nil || hovered == day.date ? 1 : 0.45))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
            if let h = hovered, let day = s.perDay.first(where: { $0.date == h }) {
                RuleMark(x: .value("Day", h, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.formatted(.dateTime.weekday(.abbreviated).month().day())).font(.caption2).foregroundStyle(.secondary)
                            Text("\(day.stats.words.formatted()) words").font(.caption.weight(.semibold))
                            Text("\(day.stats.fixedTotal) fixes").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: s.perDay.count > 7 ? 5 : 1)) { _ in
                AxisValueLabel(format: s.perDay.count > 7 ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            guard let plot = proxy.plotFrame else { return }
                            let x = p.x - g[plot].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                hovered = s.perDay.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.date
                            }
                        case .ended: hovered = nil
                        }
                    }
            }
        }
        .frame(height: 180)
        .padding(.vertical, 6)
    }
}

struct StatTile: View {
    var title: String
    var value: Int
    var previous: Int
    var range: StatsRange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            trend.font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var trend: some View {
        let label = range == .day ? "yesterday" : "previous \(range.days) days"
        if previous == 0 {
            Text(value == 0 ? " " : "New vs \(label)").foregroundStyle(.tertiary)
        } else {
            let change = Double(value - previous) / Double(previous)
            HStack(spacing: 2) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text("\(abs(change).formatted(.percent.precision(.fractionLength(0)))) vs \(label)")
            }
            .foregroundStyle(.secondary)
        }
    }
}
