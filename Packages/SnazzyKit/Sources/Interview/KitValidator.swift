import Foundation

/// Checks a kit before approval. Errors block approval; warnings are shown and
/// the recruiter decides.
public enum KitValidator {
    public struct Issue: Hashable, Sendable {
        public enum Severity: String, Sendable { case error, warning }
        public var severity: Severity
        public var message: String
        /// The competency or question it's about, if any.
        public var subject: String?

        public init(_ severity: Severity, _ message: String, subject: String? = nil) {
            self.severity = severity
            self.message = message
            self.subject = subject
        }
    }

    public static func check(_ kit: RoleKit) -> [Issue] {
        var issues: [Issue] = []
        func error(_ m: String, _ s: String? = nil) { issues.append(Issue(.error, m, subject: s)) }
        func warn(_ m: String, _ s: String? = nil) { issues.append(Issue(.warning, m, subject: s)) }

        if kit.title.trimmed.isEmpty { error("Give the role a title.") }
        if kit.competencies.isEmpty { error("Add at least one competency.") }
        if kit.competencies.count > 8 { warn("More than 8 competencies makes a first-round interview long and shallow.") }
        if kit.questions.isEmpty { error("Add at least one core question.") }
        if kit.eligibility.count > 5 { warn("More than 5 eligibility questions; keep only hard requirements.") }

        let ids = kit.competencies.map(\.id) + kit.questions.map(\.id) + kit.eligibility.map(\.id)
        for id in Set(ids) where ids.filter({ $0 == id }).count > 1 { error("The id “\(id)” is used twice.", id) }
        for id in ids where id.trimmed.isEmpty { error("Every competency and question needs an id.") }

        let weights = kit.competencies.reduce(0) { $0 + $1.weight }
        if !kit.competencies.isEmpty, weights != 100 { warn("Competency weights add up to \(weights), not 100.") }

        for c in kit.competencies {
            if c.name.trimmed.isEmpty { error("A competency has no name.", c.id) }
            if c.anchors.level1.trimmed.isEmpty || c.anchors.level3.trimmed.isEmpty || c.anchors.level5.trimmed.isEmpty {
                error("“\(c.name)” needs rubric anchors for levels 1, 3 and 5.", c.id)
            }
            if !kit.questions.contains(where: { $0.competency == c.id }) {
                error("No question gathers evidence for “\(c.name)”.", c.id)
            }
            for problem in BannedTopics.find(in: [c.name, c.description, c.anchors.level1, c.anchors.level3, c.anchors.level5].joined(separator: " ")) {
                warn("“\(c.name)” mentions \(problem). Rubrics should describe what people did, not who they are.", c.id)
            }
        }
        for q in kit.questions {
            if q.text.trimmed.isEmpty { error("A question has no text.", q.id) }
            if kit.competency(q.competency) == nil { error("Question “\(q.id)” isn't linked to a competency in this kit.", q.id) }
            for problem in BannedTopics.find(in: q.text) { error("Question “\(q.id)” asks about \(problem).", q.id) }
            if q.text.filter({ $0 == "?" }).count > 2 { warn("Question “\(q.id)” asks several things at once; candidates answer better one at a time.", q.id) }
        }
        for e in kit.eligibility {
            if e.text.trimmed.isEmpty { error("An eligibility question has no text.", e.id) }
            for problem in BannedTopics.find(in: e.text, allowCriminalRecord: kit.allowsCriminalRecordQuestion) {
                error("Eligibility question “\(e.id)” asks about \(problem).", e.id)
            }
            if BannedTopics.asksSalaryHistory(e.text) {
                error("Eligibility question “\(e.id)” asks for salary history. Ask for expectations instead.", e.id)
            }
            if e.kind == .choice, e.options.count < 2 { error("Eligibility question “\(e.id)” needs at least two options.", e.id) }
        }
        if kit.companyFacts.trimmed.isEmpty {
            warn("Add company facts (hours, pay range, team, process) so the interviewer can answer candidates' questions.")
        }
        if kit.settings.minutes < 10 || kit.settings.minutes > 60 { warn("Interviews between 10 and 60 minutes work best.") }
        if kit.settings.maxFollowUps > 3 { warn("More than 3 follow-ups per question can feel like an interrogation.") }
        return issues
    }

    public static func canApprove(_ kit: RoleKit) -> Bool { !check(kit).contains { $0.severity == .error } }
}

extension RoleKit {
    /// A criminal-record question needs the legal basis written in the company facts
    /// ("Legal basis for criminal record question: …").
    var allowsCriminalRecordQuestion: Bool {
        companyFacts.lowercased().contains("legal basis for criminal record question:")
    }
}

/// Topics an interview never raises (§3.2 of docs/plans/PROMPT_INTERVIEW.md). A
/// keyword screen for kits and for what candidates volunteer; it errs towards
/// flagging, and a person reviews what it finds.
public enum BannedTopics {
    public static let topics: [(name: String, patterns: [String])] = [
        ("age", [#"\bhow old\b"#, #"\byour age\b"#, #"\bdate of birth\b"#, #"\bborn in\b"#, #"\byear you were born\b"#, #"\bretirement age\b"#,
                 #"\byoung\b"#, #"\bdigital native\b"#, #"\brecent graduates? only\b"#, #"\bi'?m \d{2} years old\b"#, #"\bi am \d{2}\b"#]),
        ("marital or family status", [#"\bmarried\b"#, #"\bmarital\b"#, #"\bhusband\b"#, #"\bwife\b"#, #"\bspouse\b"#, #"\bdivorc\w*\b"#,
                                      #"\bchildcare\b"#, #"\bhave (any )?(kids|children)\b"#, #"\bmy (kids|children|son|daughter)\b"#]),
        ("pregnancy", [#"\bpregnan\w*\b"#, #"\bmaternity\b"#, #"\bpaternity\b"#, #"\bstart(ing)? a family\b"#, #"\bexpecting a baby\b"#]),
        ("religion", [#"\breligio\w*\b"#, #"\bchurch\b"#, #"\bmosque\b"#, #"\bsynagogue\b"#, #"\bpray(ing|er|ers)?\b"#, #"\b(your|my) faith\b"#]),
        ("nationality or ethnicity", [#"\bnationality\b"#, #"\bethnic\w*\b"#, #"\brace\b"#, #"\bwhere are you (really )?from\b"#,
                                      #"\bnative (english )?speaker\b"#, #"\bmother tongue\b"#, #"\bcitizenship\b"#, #"\bimmigra\w*\b"#,
                                      #"\baccent\b"#]),
        ("health or disability", [#"\bdisab\w*\b"#, #"\bhealth\b"#, #"\bmedical\b"#, #"\billness\b"#, #"\bsick (leave|days)\b"#,
                                  #"\bmedication\b"#, #"\bdiagnos\w*\b"#, #"\bmental health\b"#, #"\bdepression\b"#, #"\banxiety\b"#,
                                  #"\badhd\b"#, #"\bautis\w*\b"#, #"\bdyslexi\w*\b"#, #"\bcancer\b"#, #"\bwheelchair\b"#]),
        ("sexual orientation or gender identity", [#"\bsexual\w*\b"#, #"\bgay\b"#, #"\blesbian\b"#, #"\bbisexual\b"#, #"\btransgender\b"#,
                                                   #"\bgender identity\b"#, #"\bboyfriend\b"#, #"\bgirlfriend\b"#, #"\bpartner'?s gender\b"#]),
        ("union membership", [#"\btrade union\b"#, #"\bunion member\w*\b"#, #"\bunioni[sz]\w*\b"#]),
        ("political views", [#"\bpolitical (views?|party|parties|affiliation|beliefs?|opinions?)\b"#, #"\bvote[ds]? for\b"#, #"\bwhich party\b"#]),
        ("appearance", [#"\bphoto of you\b"#, #"\bappearance\b"#, #"\bhow you look\b"#, #"\bheight and weight\b"#, #"\battractive\b"#]),
        ("criminal record", [#"\bcriminal\b"#, #"\bconvict\w*\b"#, #"\barrest\w*\b"#, #"\bprison\b"#, #"\bjail\b"#]),
    ]

    /// Everyday phrases that contain a topic's words but aren't about it.
    static let benign = [
        "health and safety", "health & safety", "health check", "healthcheck", "system health", "service health",
        "race condition", "data race", "race to", "office politics", "european union", "union of", "union type",
        "sexual harassment policy", "faith in the team", "team health", "account health", "customer health", "health score",
        "system health", "health metrics", "health of the", "healthy", "data health", "pipeline health", "code health",
    ]

    /// The banned topics a text touches (names only).
    public static func find(in text: String, allowCriminalRecord: Bool = false) -> [String] {
        var lower = text.lowercased()
        for phrase in benign { lower = lower.replacingOccurrences(of: phrase, with: " ") }
        return topics.compactMap { topic in
            if allowCriminalRecord, topic.name == "criminal record" { return nil }
            return topic.patterns.contains { lower.range(of: $0, options: .regularExpression) != nil } ? topic.name : nil
        }
    }

    /// The character ranges in a text that touch a banned topic, widened to the
    /// whole sentence, for redaction before evaluation.
    public static func sentences(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sub, range, _, _ in
            if let sub, !find(in: sub).isEmpty { ranges.append(range) }
        }
        return ranges
    }

    static func asksSalaryHistory(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns = [#"\b(current|previous|last|past|present) (salary|pay|wage|compensation)\b"#,
                        #"\bsalary history\b"#, #"\bhow much (do|did) you (earn|make|get paid)\b"#,
                        #"\bwhat (do|did) you (earn|make)\b"#]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
