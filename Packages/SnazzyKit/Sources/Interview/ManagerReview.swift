import Foundation

// What a hiring manager works with after the interviews: each candidate's levels next to
// the AI's suggestions, a comparison per role and a brief for the next round. None of it
// ranks, scores or decides: there is no overall score, and the default order is by name
// or date. Voluntary self-ID answers are stored apart and never appear here.

/// One competency's level for one interview, and whose it is.
public struct LevelCell: Hashable, Sendable {
    public enum Source: String, Sendable {
        /// Set by a person.
        case reviewer
        /// The AI's suggestion, not yet looked at by a person.
        case ai
        /// Nothing yet (no evaluation, or ratings are off).
        case none
    }

    /// 1–5, or nil for "not enough evidence" (when `source` isn't `.none`).
    public var level: Int?
    public var source: Source

    public init(level: Int?, source: Source) {
        self.level = level
        self.source = source
    }

    /// "4", "4 (AI)", "Not enough evidence", or "–".
    public var text: String {
        switch source {
        case .none: "–"
        case .reviewer: level.map(String.init) ?? "Not enough evidence"
        case .ai: level.map { "\($0) (AI)" } ?? "Not enough evidence (AI)"
        }
    }

    /// The person's level wins; the AI's suggestion shows only until a person sets one.
    public static func cell(_ s: InterviewSession, competency id: String) -> LevelCell {
        if let mine = s.review?.levels[id] { return LevelCell(level: mine == 0 ? nil : mine, source: .reviewer) }
        guard s.kit.settings.ratingsEnabled, let r = s.evaluation?.result(id) else { return LevelCell(level: nil, source: .none) }
        return LevelCell(level: r.level, source: .ai)
    }
}

public enum ReviewLevels {
    /// One readable line per level a person changed, for the audit trail, e.g.
    /// "Teamwork: AI suggested 3, set to 4" or "Teamwork: 4 → not enough evidence".
    /// `before`/`after` are the reviewer's levels by competency id (0 = not enough evidence).
    public static func changes(kit: RoleKit, evaluation: Evaluation?, before: [String: Int], after: [String: Int]) -> [String] {
        func text(_ level: Int?) -> String {
            guard let level else { return "not set" }
            return level == 0 ? "not enough evidence" : String(level)
        }
        var lines: [String] = []
        for c in kit.competencies {
            let old = before[c.id], new = after[c.id]
            guard old != new else { continue }
            let name = c.name.isEmpty ? c.id : c.name
            if old == nil, kit.settings.ratingsEnabled, let r = evaluation?.result(c.id) {
                let ai = r.level.map(String.init) ?? "not enough evidence"
                lines.append("\(name): AI suggested \(ai), set to \(text(new))")
            } else {
                lines.append("\(name): \(text(old)) → \(text(new))")
            }
        }
        return lines
    }
}

/// Every finished interview for one role, side by side.
public struct RoleComparison: Sendable {
    public enum Sort: Hashable, Sendable {
        case name, date
        /// By one competency's level, highest first: a click the reviewer makes, never the default.
        case level(String)
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var candidate: String
        public var date: Date
        /// Which kit version the interview used.
        public var kitVersion: Int
        public var status: String
        public var decision: Review.Decision?
        public var cells: [String: LevelCell]
        /// Flags worth a look before comparing (adjustment, asked for a person, technical problem…).
        public var flags: [String]
    }

    public var competencies: [Competency]
    public var rows: [Row]

    /// Interviews for the kit with `kitID` (any version) that have finished.
    public init(kitID: UUID, competencies: [Competency], sessions: [InterviewSession]) {
        self.competencies = competencies
        rows = sessions.filter { $0.kit.id == kitID && $0.isFinished }.map { s in
            Row(id: s.id,
                candidate: s.candidate.name.isEmpty ? "Candidate" : s.candidate.name,
                date: s.endedAt ?? s.startedAt ?? s.created,
                kitVersion: s.kit.version,
                status: Self.status(s),
                decision: s.review?.decision,
                cells: Dictionary(uniqueKeysWithValues: competencies.map { ($0.id, LevelCell.cell(s, competency: $0.id)) }),
                flags: Array(Set(s.flags.map(\.label))).sorted())
        }
        rows = sorted(by: .name)
    }

    public static func status(_ s: InterviewSession) -> String {
        if let d = s.review?.decision { return d.label }
        if s.review != nil { return "Reviewing" }
        switch s.state {
        case .humanRequested: return "Asked for a person"
        case .withdrawn: return "Withdrew"
        case .abandoned, .expired: return "Not finished"
        default: return "To review"
        }
    }

    public func sorted(by sort: Sort) -> [Row] {
        switch sort {
        case .name:
            return rows.sorted { ($0.candidate.localizedLowercase, $0.date) < ($1.candidate.localizedLowercase, $1.date) }
        case .date:
            return rows.sorted { $0.date > $1.date }
        case .level(let id):
            // Highest first; "not enough evidence" and unrated after every level; ties by name.
            func key(_ r: Row) -> Int { r.cells[id]?.level ?? 0 }
            return rows.sorted { key($0) != key($1) ? key($0) > key($1) : $0.candidate.localizedLowercase < $1.candidate.localizedLowercase }
        }
    }

    /// A CSV of the rows in `order` (for a spreadsheet or an ATS). AI levels are marked "(AI)".
    public func csv(order: [Row]) -> String {
        func field(_ s: String) -> String {
            var s = s
            // Keep spreadsheets from treating a cell as a formula.
            if let first = s.first, "=+-@\t\r".contains(first) { s = "'" + s }
            return s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let iso = ISO8601DateFormatter()
        var lines = [(["Candidate", "Interviewed", "Kit version", "Status"] + competencies.map(\.name) + ["Flags"]).map(field).joined(separator: ",")]
        for r in order {
            let cells = competencies.map { r.cells[$0.id]?.text ?? "–" }
            lines.append(([r.candidate, iso.string(from: r.date), "v\(r.kitVersion)", r.status] + cells + [r.flags.joined(separator: "; ")])
                .map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A brief for whoever interviews the candidate next: what was asked, the evidence,
/// the levels (the reviewer's next to the AI's suggestion), what to probe, and the
/// reviewer's decision and note. Markdown, so it pastes anywhere.
public enum HiringBrief {
    public static func markdown(_ s: InterviewSession, now: Date = Date()) -> String {
        let name = s.candidate.name.isEmpty ? "Candidate" : s.candidate.name
        let day = { (d: Date) in d.formatted(date: .abbreviated, time: .omitted) }
        var out = ["# \(name): \(s.kit.title)", ""]
        var facts = ["Interviewed \(day(s.endedAt ?? s.startedAt ?? s.created))", "kit v\(s.kit.version)"]
        if !s.kit.organisation.isEmpty { facts.insert(s.kit.organisation, at: 0) }
        if !s.candidate.reference.isEmpty { facts.append("ref \(s.candidate.reference)") }
        out.append(facts.joined(separator: " · "))
        out.append("")

        if let r = s.review {
            out.append("## Decision so far")
            out.append("")
            let who = r.reviewer.isEmpty ? "the reviewer" : r.reviewer
            out.append(r.decision.map { "**\($0.label)** by \(who) on \(day(r.at)): \(r.reason)" } ?? "Not decided yet (reviewed by \(who)).")
            if !r.note.isEmpty { out.append(""); out.append("> " + r.note.replacingOccurrences(of: "\n", with: "\n> ")) }
            out.append("")
        }

        let probes = s.kit.competencies.compactMap { c in s.evaluation?.result(c.id).flatMap { $0.probeNext.isEmpty ? nil : "- **\(c.name):** \($0.probeNext)" } }
        if !probes.isEmpty {
            out.append("## Ask in the next round")
            out.append("")
            out += probes
            out.append("")
        }

        out.append("## Evidence by competency")
        out.append("")
        for c in s.kit.competencies {
            let mine = s.review?.levels[c.id]
            var heading = "### \(c.name) (\(c.weight)%)"
            if s.kit.settings.ratingsEnabled {
                var parts: [String] = []
                if let mine { parts.append("reviewer: \(mine == 0 ? "not enough evidence" : String(mine))") }
                if let r = s.evaluation?.result(c.id) { parts.append("AI suggested: \(r.level.map(String.init) ?? "not enough evidence")") }
                if !parts.isEmpty { heading += ": " + parts.joined(separator: ", ") }
            }
            out.append(heading)
            out.append("")
            if let r = s.evaluation?.result(c.id) {
                if r.evidence.isEmpty { out.append("No evidence in the answers.") }
                for q in r.evidence { out.append("- “\(q.quote)”") }
                if !r.agreed { out.append(""); out.append("_Two AI runs disagreed here; read the transcript._") }
            } else {
                out.append("No evidence summary yet.")
            }
            out.append("")
        }

        let eligibility = s.kit.eligibility.compactMap { q in s.eligibilityAnswers[q.id].map { "- \(q.text) **\($0)**" } }
        if !eligibility.isEmpty {
            out.append("## Eligibility answers (as given)")
            out.append("")
            out += eligibility
            out.append("")
        }
        // Adjustments and other flags the next interviewer should know; personal details
        // the candidate volunteered stay hidden.
        let flags = Array(Set(s.flags.filter { $0.kind != .protectedInfoVolunteered }.map(\.label))).sorted()
        if !flags.isEmpty || !s.adjustments.isEmpty || !s.forwardedQuestions.isEmpty {
            out.append("## Good to know")
            out.append("")
            out += flags.map { "- \($0)" }
            out += s.adjustments.map { "- Adjustment asked for: \($0)" }
            out += s.forwardedQuestions.map { "- The candidate asked: \($0)" }
            out.append("")
        }
        out.append("---")
        out.append("A person on the hiring team makes every decision. AI levels are suggestions only. Prepared \(day(now)).")
        return out.joined(separator: "\n") + "\n"
    }
}
