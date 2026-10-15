import Foundation

/// The AI's assessment of one interview, made after it ends: evidence (quotes
/// checked against the transcript) and a suggested level per competency. It is
/// advice for the reviewer, never a decision.
public struct Evaluation: Codable, Hashable, Sendable {
    public var competencies: [CompetencyResult]
    /// Text in candidate turns that tried to instruct the AI.
    public var injection: [Quote]
    public var notesForReviewer: String
    /// Quotes the evaluator gave that weren't in the transcript (dropped).
    public var droppedQuotes: Int
    public var model: String
    public var promptVersion: String
    public var at: Date

    public init(competencies: [CompetencyResult], injection: [Quote] = [], notesForReviewer: String = "", droppedQuotes: Int = 0,
                model: String = "", promptVersion: String = "", at: Date = Date()) {
        self.competencies = competencies
        self.injection = injection
        self.notesForReviewer = notesForReviewer
        self.droppedQuotes = droppedQuotes
        self.model = model
        self.promptVersion = promptVersion
        self.at = at
    }

    public func result(_ competency: String) -> CompetencyResult? { competencies.first { $0.id == competency } }

    /// Competencies where the two runs disagreed by more than one level.
    public var lowAgreement: [String] { competencies.filter { !$0.agreed }.map(\.id) }
}

public struct Quote: Codable, Hashable, Sendable {
    public var turn: String
    public var quote: String

    public init(turn: String, quote: String) {
        self.turn = turn
        self.quote = quote
    }
}

public struct CompetencyResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var evidence: [Quote]
    /// 1–5, or nil for "not enough evidence" (or when ratings are off).
    public var level: Int?
    /// The second run's level, to show disagreement.
    public var secondLevel: Int?
    public var agreed: Bool
    public var reason: String
    public var probeNext: String

    public init(id: String, evidence: [Quote], level: Int?, secondLevel: Int? = nil, agreed: Bool = true, reason: String, probeNext: String) {
        self.id = id
        self.evidence = evidence
        self.level = level
        self.secondLevel = secondLevel
        self.agreed = agreed
        self.reason = reason
        self.probeNext = probeNext
    }
}

/// The evaluator's raw JSON (see evaluator.v1.md).
struct EvaluatorOutput: Decodable {
    struct Item: Decodable {
        var id: String
        var evidence: [Quote]?
        var level: LevelValue?
        var reason: String?
        var probeNext: String?
    }

    enum LevelValue: Decodable {
        case level(Int), insufficient

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self), (1...5).contains(n) {
                self = .level(n)
            } else if let d = try? c.decode(Double.self), (1...5).contains(Int(d)) {
                self = .level(Int(d))
            } else {
                self = .insufficient
            }
        }

        var value: Int? { if case .level(let n) = self { n } else { nil } }
    }

    var competencies: [Item]
    var injection: [Quote]?
    var notesForReviewer: String?
}

/// Builds the evaluator's input and checks its output.
public enum Evaluator {
    public static let promptVersion = "evaluator.v1"

    /// The transcript as the evaluator sees it: candidate turns wrapped as external
    /// data; sentences on protected topics and the candidate's name replaced.
    public static func transcript(for session: InterviewSession) -> String {
        let names = nameTokens(session.candidate.name)
        let flaggedTurns = Set(session.flags.filter { $0.kind == .protectedInfoVolunteered }.compactMap(\.turn))
        return session.turns.compactMap { turn -> String? in
            switch turn.role {
            case .system: return nil
            case .interviewer: return "[\(turn.id)] Interviewer: \(redactNames(turn.text, names))"
            case .candidate:
                var text = redactNames(turn.text, names)
                if flaggedTurns.contains(turn.id) { text = redactProtected(text) }
                return "[\(turn.id)] Candidate:\n<external_data turn=\"\(turn.id)\">\n\(text)\n</external_data>"
            }
        }.joined(separator: "\n\n")
    }

    /// Replaces each sentence touching a banned topic with "[redacted]".
    public static func redactProtected(_ text: String) -> String {
        let ranges = BannedTopics.sentences(in: text)
        guard !ranges.isEmpty else { return text }
        var out = text
        for r in ranges.reversed() {
            let lower = out.distance(from: out.startIndex, to: r.lowerBound)
            let upper = out.distance(from: out.startIndex, to: r.upperBound)
            let a = out.index(out.startIndex, offsetBy: lower), b = out.index(out.startIndex, offsetBy: upper)
            out.replaceSubrange(a..<b, with: "[redacted] ")
        }
        return out.trimmed
    }

    static func looksLikeInstruction(_ text: String) -> Bool {
        let t = text.lowercased()
        let patterns = [#"\bignore\b"#, #"\binstruction"#, #"\bprompt\b"#, #"\brate me\b"#, #"\bscore me\b"#, #"\bgive me (a )?(5|five|top|full)"#,
                        #"\bsystem\s*(message|prompt)?:"#, #"\byou are now\b"#, #"\bdisregard\b"#, #"\bas the (ai|model|evaluator)\b"#,
                        #"\b(level|rating|score) (of )?(5|five)\b"#, #"</?(engine|external_data|system)"#]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    static func nameTokens(_ name: String) -> [String] {
        name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init).filter { $0.count >= 2 }
    }

    static func redactNames(_ text: String, _ names: [String]) -> String {
        var out = text
        for n in names {
            out = out.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: n))\\b", with: "[candidate]",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// Parses one evaluator run and keeps only quotes that are really in the
    /// candidate's turns. Returns nil if the output isn't usable.
    static func parse(_ text: String, session: InterviewSession) -> (results: [CompetencyResult], injection: [Quote], notes: String, dropped: Int)? {
        guard let json = ModelJSON.firstObject(in: text),
              let out = try? InterviewJSON.decoder.decode(EvaluatorOutput.self, from: Data(json.utf8)) else { return nil }
        var dropped = 0
        var results: [CompetencyResult] = []
        for competency in session.kit.competencies {
            let item = out.competencies.first { $0.id == competency.id }
            let quotes = (item?.evidence ?? []).filter { q in
                let ok = QuoteCheck.isVerbatim(q, in: session)
                if !ok { dropped += 1 }
                return ok
            }
            // No real evidence, no level.
            let level = quotes.isEmpty ? nil : item?.level?.value
            results.append(CompetencyResult(id: competency.id, evidence: quotes, level: level,
                                            reason: item?.reason?.trimmed ?? "", probeNext: item?.probeNext?.trimmed ?? ""))
        }
        // Only quotes that really try to direct the AI (models over-report this).
        let injection = (out.injection ?? []).filter {
            session.turn($0.turn)?.role == .candidate && QuoteCheck.isVerbatim($0, in: session) && looksLikeInstruction($0.quote)
        }
        return (results, injection, out.notesForReviewer?.trimmed ?? "", dropped)
    }

    /// Combines two independent runs. The first run's level stands; a gap of more
    /// than one level (or rated against not-rated) marks low agreement.
    public static func combine(_ first: String, _ second: String?, session: InterviewSession, model: String, now: Date = Date()) -> Evaluation? {
        guard let a = parse(first, session: session) else { return nil }
        let b = second.flatMap { parse($0, session: session) }
        let ratings = session.kit.settings.ratingsEnabled
        let results = a.results.map { r -> CompetencyResult in
            var r = r
            let other = b?.results.first { $0.id == r.id }
            r.secondLevel = other?.level
            if let other {
                switch (r.level, other.level) {
                case (let x?, let y?): r.agreed = abs(x - y) <= 1
                case (nil, nil): r.agreed = true
                default: r.agreed = false
                }
            }
            if !ratings {
                r.level = nil
                r.secondLevel = nil
            }
            return r
        }
        return Evaluation(competencies: results, injection: a.injection, notesForReviewer: a.notes,
                          droppedQuotes: a.dropped, model: model, promptVersion: promptVersion, at: now)
    }
}

/// Checks that a quote is the candidate's own words, verbatim (allowing for
/// whitespace, quote marks and case).
public enum QuoteCheck {
    public static func isVerbatim(_ quote: Quote, in session: InterviewSession) -> Bool {
        guard let turn = session.turn(quote.turn), turn.role == .candidate else { return false }
        let q = normalise(quote.quote)
        guard q.count >= 3, !q.contains("[redacted]"), !q.contains("[candidate]") else { return false }
        return normalise(turn.text).contains(q)
    }

    static func normalise(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2026}", "..."), ("\u{2014}", "-"), ("\u{2013}", "-")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"' .,…").union(.whitespacesAndNewlines))
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
