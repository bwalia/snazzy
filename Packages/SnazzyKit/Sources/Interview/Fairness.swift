import Foundation

/// Voluntary self-ID, given after the interview. Stored apart from interviews,
/// never shown to the AI or a reviewer, and reported only in aggregate.
public struct SelfID: Codable, Hashable, Sendable {
    public var key: String
    /// Answers by question ("gender", "ethnicity", "age_band", "disability"); "prefer not to say" is an answer.
    public var answers: [String: String]
    public var at: Date

    public init(key: String, answers: [String: String], at: Date = Date()) {
        self.key = key
        self.answers = answers
        self.at = at
    }

    public static let questions: [(id: String, label: String, options: [String])] = [
        ("gender", "Gender", ["Woman", "Man", "Non-binary", "Another way", "Prefer not to say"]),
        ("age_band", "Age", ["Under 25", "25–39", "40–54", "55 or over", "Prefer not to say"]),
        ("ethnicity", "Ethnic group", ["Asian or Asian British", "Black, African, Caribbean or Black British", "Mixed or multiple",
                                       "White", "Another ethnic group", "Prefer not to say"]),
        ("disability", "Do you consider yourself disabled?", ["Yes", "No", "Prefer not to say"]),
    ]
}

/// Selection rates and impact ratios by group, per stage (§3.3 of the plan).
public enum Fairness {
    /// Groups smaller than this are not reported.
    public static let minimumGroup = 10
    /// The four-fifths guideline.
    public static let warnBelow = 0.8

    public struct Row: Hashable, Sendable {
        public var group: String
        public var total: Int
        public var selected: Int
        public var rate: Double
        /// rate ÷ the highest rate among reported groups.
        public var impactRatio: Double
        public var warning: Bool
    }

    public struct Report: Hashable, Sendable {
        public var question: String
        public var rows: [Row]
        /// Groups left out for being smaller than `minimumGroup`.
        public var suppressed: Int
    }

    /// Advance rate by group for one self-ID question. `outcomes` maps a self-ID key to
    /// whether that candidate was advanced (decided interviews only).
    public static func report(question: String, selfIDs: [SelfID], outcomes: [String: Bool]) -> Report {
        var totals: [String: (Int, Int)] = [:]
        for s in selfIDs {
            guard let advanced = outcomes[s.key], let group = s.answers[question], !group.isEmpty else { continue }
            var t = totals[group] ?? (0, 0)
            t.0 += 1
            if advanced { t.1 += 1 }
            totals[group] = t
        }
        let reported = totals.filter { $0.value.0 >= minimumGroup }
        let best = reported.values.map { Double($0.1) / Double($0.0) }.max() ?? 0
        let rows = reported.map { group, t -> Row in
            let rate = Double(t.1) / Double(t.0)
            let ratio = best > 0 ? rate / best : 1
            return Row(group: group, total: t.0, selected: t.1, rate: rate, impactRatio: ratio, warning: ratio < warnBelow)
        }.sorted { $0.group < $1.group }
        return Report(question: question, rows: rows, suppressed: totals.count - reported.count)
    }
}
