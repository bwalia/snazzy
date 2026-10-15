import Foundation

/// A role's interview kit: what the role needs (competencies with rubric
/// anchors), the questions every candidate gets, the eligibility questions and
/// the facts the interviewer may share. A recruiter edits and approves it; only
/// an approved kit runs interviews. The format is shared with OpsAPI
/// (docs/specs/interview-kit.md), so it decodes tolerantly.
public struct RoleKit: Codable, Hashable, Sendable, Identifiable {
    public static let formatVersion = 1

    public var id: UUID
    public var format: Int
    /// Bumped on every approval; each interview records the version it used.
    public var version: Int
    public var title: String
    public var organisation: String
    /// A paragraph about the role, read by the interviewer.
    public var summary: String
    /// BCP 47 language of the interview, e.g. "en-GB".
    public var language: String
    public var jobDescription: String
    public var competencies: [Competency]
    public var eligibility: [EligibilityQuestion]
    public var questions: [CoreQuestion]
    /// What the interviewer may tell candidates (hours, pay range, team, process).
    public var companyFacts: String
    public var settings: Settings
    public var approvedAt: Date?
    public var approvedBy: String?
    /// Problems the kit generator saw in the job description, with suggested rewording.
    public var warnings: [String]
    public var created: Date
    public var updated: Date

    public var isApproved: Bool { approvedAt != nil }

    public init(
        id: UUID = UUID(), title: String, organisation: String = "", summary: String = "", language: String = "en-GB",
        jobDescription: String = "", competencies: [Competency] = [], eligibility: [EligibilityQuestion] = [],
        questions: [CoreQuestion] = [], companyFacts: String = "", settings: Settings = Settings(),
        warnings: [String] = [], now: Date = Date()
    ) {
        self.id = id
        self.format = Self.formatVersion
        self.version = 0
        self.title = title
        self.organisation = organisation
        self.summary = summary
        self.language = language
        self.jobDescription = jobDescription
        self.competencies = competencies
        self.eligibility = eligibility
        self.questions = questions
        self.companyFacts = companyFacts
        self.settings = settings
        self.warnings = warnings
        self.created = now
        self.updated = now
    }

    enum CodingKeys: String, CodingKey {
        case id, format, version, title, organisation, summary, language, jobDescription, competencies, eligibility,
             questions, companyFacts, settings, approvedAt, approvedBy, warnings, created, updated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? Self.formatVersion
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled role"
        organisation = try c.decodeIfPresent(String.self, forKey: .organisation) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en-GB"
        jobDescription = try c.decodeIfPresent(String.self, forKey: .jobDescription) ?? ""
        competencies = try c.decodeIfPresent([Competency].self, forKey: .competencies) ?? []
        eligibility = try c.decodeIfPresent([EligibilityQuestion].self, forKey: .eligibility) ?? []
        questions = try c.decodeIfPresent([CoreQuestion].self, forKey: .questions) ?? []
        // Generators sometimes give lists; keep them as lines.
        companyFacts = (try? c.decodeIfPresent(String.self, forKey: .companyFacts))
            ?? (try? c.decodeIfPresent([String].self, forKey: .companyFacts))?.joined(separator: "\n") ?? ""
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        approvedAt = try c.decodeIfPresent(Date.self, forKey: .approvedAt)
        approvedBy = try c.decodeIfPresent(String.self, forKey: .approvedBy)
        warnings = (try? c.decodeIfPresent([String].self, forKey: .warnings))
            ?? (try? c.decodeIfPresent([[String: String]].self, forKey: .warnings))?.map { $0.values.sorted().joined(separator: " → ") } ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? created
    }

    public func competency(_ id: String) -> Competency? { competencies.first { $0.id == id } }

    /// Approves the kit: a new version that interviews can use.
    public mutating func approve(by reviewer: String, now: Date = Date()) {
        version += 1
        approvedAt = now
        approvedBy = reviewer
        updated = now
    }

    /// Any edit after approval needs a new approval.
    public mutating func markEdited(now: Date = Date()) {
        approvedAt = nil
        approvedBy = nil
        updated = now
    }
}

public struct Competency: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    /// Relative weight; a kit's weights add up to 100.
    public var weight: Int
    /// The line of the job description it comes from.
    public var source: String
    /// Behavioural anchors for levels 1, 3 and 5 (2 and 4 fall between).
    public var anchors: Anchors

    public struct Anchors: Codable, Hashable, Sendable {
        public var level1: String
        public var level3: String
        public var level5: String

        public init(level1: String = "", level3: String = "", level5: String = "") {
            self.level1 = level1
            self.level3 = level3
            self.level5 = level5
        }

        enum CodingKeys: String, CodingKey { case level1 = "1", level3 = "3", level5 = "5" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            level1 = try c.decodeIfPresent(String.self, forKey: .level1) ?? ""
            level3 = try c.decodeIfPresent(String.self, forKey: .level3) ?? ""
            level5 = try c.decodeIfPresent(String.self, forKey: .level5) ?? ""
        }
    }

    public init(id: String, name: String, description: String = "", weight: Int = 0, source: String = "", anchors: Anchors = Anchors()) {
        self.id = id
        self.name = name
        self.description = description
        self.weight = weight
        self.source = source
        self.anchors = anchors
    }

    enum CodingKeys: String, CodingKey { case id, name, description, weight, source, anchors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        weight = c.flexibleInt(.weight) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        anchors = try c.decodeIfPresent(Anchors.self, forKey: .anchors) ?? Anchors()
    }
}

/// A hard requirement, asked word for word, with fixed answers. The answer is
/// shown to the recruiter as given; the AI never judges it.
public struct EligibilityQuestion: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case yesNo = "yes_no", choice, text
    }

    public var id: String
    public var text: String
    public var kind: Kind
    /// For `choice`.
    public var options: [String]
    /// The answers that meet the requirement (shown to the recruiter, never used to reject).
    public var accepted: [String]

    public init(id: String, text: String, kind: Kind = .yesNo, options: [String] = [], accepted: [String] = []) {
        self.id = id
        self.text = text
        self.kind = kind
        self.options = options
        self.accepted = accepted
    }

    enum CodingKeys: String, CodingKey { case id, text, kind, options, accepted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .text
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        accepted = try c.decodeIfPresent([String].self, forKey: .accepted) ?? []
    }

    /// The choices a candidate picks from (nil: free text).
    public var choices: [String]? {
        switch kind {
        case .yesNo: ["Yes", "No"]
        case .choice: options.isEmpty ? nil : options
        case .text: nil
        }
    }

    /// Whether an answer meets the requirement; nil when the kit doesn't say.
    public func meets(_ answer: String) -> Bool? {
        guard !accepted.isEmpty else { return nil }
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return accepted.contains { $0.lowercased() == a }
    }
}

public struct CoreQuestion: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case behavioural, situational
    }

    public var id: String
    public var text: String
    public var competency: String
    public var kind: Kind

    public init(id: String, text: String, competency: String, kind: Kind = .behavioural) {
        self.id = id
        self.text = text
        self.competency = competency
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, text, competency, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        competency = try c.decodeIfPresent(String.self, forKey: .competency) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .behavioural
    }
}

extension RoleKit {
    public struct Settings: Codable, Hashable, Sendable {
        public var interviewerName: String
        public var minutes: Int
        public var maxFollowUps: Int
        /// Seconds a candidate has for one answer (0: no limit).
        public var secondsPerAnswer: Int
        public var allowVoice: Bool
        public var allowPause: Bool
        /// Adjustments the interviewer grants at once; anything else goes to the recruiter.
        public var allowedAdjustments: [String]
        public var nextSteps: String
        /// Off: evidence only, no suggested levels (NYC Local Law 144 and similar).
        public var ratingsEnabled: Bool
        /// The kit assesses written communication, so spelling and grammar may count there.
        public var writtenCommunication: Bool
        /// Days to keep an interview after the decision.
        public var retentionDays: Int
        /// Candidates may choose to turn their camera on, and the interview is then
        /// recorded for the hiring team to watch. Never required, never analysed.
        public var offerCamera: Bool

        public init(
            interviewerName: String = "Snazzy Interviewer", minutes: Int = 25, maxFollowUps: Int = 2,
            secondsPerAnswer: Int = 0, allowVoice: Bool = true, allowPause: Bool = true,
            allowedAdjustments: [String] = Self.defaultAdjustments,
            nextSteps: String = "The hiring team reviews every interview and will contact you within 5 working days.",
            ratingsEnabled: Bool = true, writtenCommunication: Bool = false, retentionDays: Int = 180, offerCamera: Bool = false
        ) {
            self.interviewerName = interviewerName
            self.minutes = minutes
            self.maxFollowUps = maxFollowUps
            self.secondsPerAnswer = secondsPerAnswer
            self.allowVoice = allowVoice
            self.allowPause = allowPause
            self.allowedAdjustments = allowedAdjustments
            self.nextSteps = nextSteps
            self.ratingsEnabled = ratingsEnabled
            self.writtenCommunication = writtenCommunication
            self.retentionDays = retentionDays
            self.offerCamera = offerCamera
        }

        public static let defaultAdjustments = [
            "extra time", "a pause", "questions repeated or rephrased", "text instead of voice", "voice instead of text",
            "large text or high contrast",
        ]

        enum CodingKeys: String, CodingKey {
            case interviewerName, minutes, maxFollowUps, secondsPerAnswer, allowVoice, allowPause, allowedAdjustments,
                 nextSteps, ratingsEnabled, writtenCommunication, retentionDays, offerCamera
        }

        public init(from decoder: Decoder) throws {
            let d = Settings()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            interviewerName = try c.decodeIfPresent(String.self, forKey: .interviewerName) ?? d.interviewerName
            minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? d.minutes
            maxFollowUps = try c.decodeIfPresent(Int.self, forKey: .maxFollowUps) ?? d.maxFollowUps
            secondsPerAnswer = try c.decodeIfPresent(Int.self, forKey: .secondsPerAnswer) ?? d.secondsPerAnswer
            allowVoice = try c.decodeIfPresent(Bool.self, forKey: .allowVoice) ?? d.allowVoice
            allowPause = try c.decodeIfPresent(Bool.self, forKey: .allowPause) ?? d.allowPause
            allowedAdjustments = try c.decodeIfPresent([String].self, forKey: .allowedAdjustments) ?? d.allowedAdjustments
            nextSteps = try c.decodeIfPresent(String.self, forKey: .nextSteps) ?? d.nextSteps
            ratingsEnabled = try c.decodeIfPresent(Bool.self, forKey: .ratingsEnabled) ?? d.ratingsEnabled
            writtenCommunication = try c.decodeIfPresent(Bool.self, forKey: .writtenCommunication) ?? d.writtenCommunication
            retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
            offerCamera = try c.decodeIfPresent(Bool.self, forKey: .offerCamera) ?? d.offerCamera
        }
    }
}

/// JSON coding shared by kits, interviews and the OpsAPI format: snake_case keys, ISO 8601 dates.
public enum InterviewJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension KeyedDecodingContainer {
    /// An integer a model may have written as a number, a decimal or text ("25", "25%").
    func flexibleInt(_ key: Key) -> Int? {
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return n }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d.rounded()) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return Int(s.trimmingCharacters(in: CharacterSet.decimalDigits.inverted))
        }
        return nil
    }
}
