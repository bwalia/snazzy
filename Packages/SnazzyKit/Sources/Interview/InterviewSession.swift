import Foundation

/// One candidate's interview: the kit it used (a snapshot), the transcript,
/// flags, the evaluation and the person's review. The transcript is append-only.
public struct InterviewSession: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case invited, inProgress = "in_progress", paused, completed, humanRequested = "human_requested"
        case abandoned, expired, withdrawn
    }

    public enum Channel: String, Codable, Sendable, CaseIterable {
        /// The candidate uses this Mac.
        case thisMac = "this_mac"
        /// The candidate opens a link from this Mac on the same network.
        case link
        /// Hosted by OpsAPI.
        case hosted
    }

    public var id: UUID
    public var kit: RoleKit
    public var candidate: Candidate
    public var channel: Channel
    public var state: State
    /// Hash of the link token (the token itself is shown once, to the recruiter).
    public var linkTokenHash: String?
    public var linkExpires: Date?
    public var turns: [Turn]
    public var flags: [Flag]
    public var eligibilityAnswers: [String: String]
    /// Adjustments the candidate asked for, in their words.
    public var adjustments: [String]
    /// The notice the candidate acknowledged (text hash + time).
    public var noticeHash: String?
    public var noticeAcceptedAt: Date?
    public var startedAt: Date?
    public var endedAt: Date?
    public var endReason: String?
    /// Seconds spent paused (not counted against the time limit).
    public var pausedSeconds: Double
    public var pausedAt: Date?
    /// The engine's position: index into `InterviewPlan.steps`, and follow-ups used there.
    public var step: Int
    public var followUps: Int
    /// Questions the interviewer couldn't answer, for the recruiter.
    public var forwardedQuestions: [String]
    /// Model and prompt versions used, e.g. ["interviewer": "anthropic/claude-sonnet-5-5 · interviewer.v1"].
    public var models: [String: String]
    public var evaluation: Evaluation?
    public var review: Review?
    /// Whether this candidate is offered the camera (from the kit, set per interview).
    public var cameraOffered: Bool
    /// The candidate's own choice about the camera, when they made it.
    public var camera: CameraConsent?
    /// The recording's files (composite movie, raw folder, chapters), deleted with the interview.
    public var recordingFiles: [String]
    /// Opaque id linking voluntary self-ID answers, which are stored apart and never shown with the interview.
    public var selfIDKey: String?
    public var audit: [AuditEntry]
    public var created: Date
    /// When this interview is deleted (set at completion and moved on decision).
    public var deleteAfter: Date?

    public init(id: UUID = UUID(), kit: RoleKit, candidate: Candidate, channel: Channel, now: Date = Date()) {
        self.id = id
        self.kit = kit
        self.candidate = candidate
        self.channel = channel
        self.state = .invited
        self.turns = []
        self.flags = []
        self.eligibilityAnswers = [:]
        self.adjustments = []
        self.pausedSeconds = 0
        self.step = 0
        self.followUps = 0
        self.forwardedQuestions = []
        self.models = [:]
        self.audit = []
        self.cameraOffered = kit.settings.offerCamera
        self.recordingFiles = []
        self.created = now
        self.deleteAfter = Calendar.current.date(byAdding: .day, value: max(kit.settings.retentionDays, 1), to: now)
    }

    enum CodingKeys: String, CodingKey {
        case id, kit, candidate, channel, state, linkTokenHash, linkExpires, turns, flags, eligibilityAnswers, adjustments,
             noticeHash, noticeAcceptedAt, startedAt, endedAt, endReason, pausedSeconds, pausedAt, step, followUps,
             forwardedQuestions, models, evaluation, review, selfIDKey = "selfIdKey", audit, created, deleteAfter,
             cameraOffered, camera, recordingFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kit = try c.decode(RoleKit.self, forKey: .kit)
        candidate = try c.decodeIfPresent(Candidate.self, forKey: .candidate) ?? Candidate(name: "")
        channel = (try? c.decodeIfPresent(Channel.self, forKey: .channel)) ?? .thisMac
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .invited
        linkTokenHash = try c.decodeIfPresent(String.self, forKey: .linkTokenHash)
        linkExpires = try c.decodeIfPresent(Date.self, forKey: .linkExpires)
        turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
        flags = try c.decodeIfPresent([Flag].self, forKey: .flags) ?? []
        eligibilityAnswers = try c.decodeIfPresent([String: String].self, forKey: .eligibilityAnswers) ?? [:]
        adjustments = try c.decodeIfPresent([String].self, forKey: .adjustments) ?? []
        noticeHash = try c.decodeIfPresent(String.self, forKey: .noticeHash)
        noticeAcceptedAt = try c.decodeIfPresent(Date.self, forKey: .noticeAcceptedAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        endReason = try c.decodeIfPresent(String.self, forKey: .endReason)
        pausedSeconds = try c.decodeIfPresent(Double.self, forKey: .pausedSeconds) ?? 0
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        step = try c.decodeIfPresent(Int.self, forKey: .step) ?? 0
        followUps = try c.decodeIfPresent(Int.self, forKey: .followUps) ?? 0
        forwardedQuestions = try c.decodeIfPresent([String].self, forKey: .forwardedQuestions) ?? []
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        evaluation = try c.decodeIfPresent(Evaluation.self, forKey: .evaluation)
        review = try c.decodeIfPresent(Review.self, forKey: .review)
        selfIDKey = try c.decodeIfPresent(String.self, forKey: .selfIDKey)
        audit = try c.decodeIfPresent([AuditEntry].self, forKey: .audit) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        deleteAfter = try c.decodeIfPresent(Date.self, forKey: .deleteAfter)
        cameraOffered = try c.decodeIfPresent(Bool.self, forKey: .cameraOffered) ?? false
        camera = try c.decodeIfPresent(CameraConsent.self, forKey: .camera)
        recordingFiles = try c.decodeIfPresent([String].self, forKey: .recordingFiles) ?? []
    }

    /// The camera is on and recording only while the candidate agrees.
    public var cameraAgreed: Bool { cameraOffered && camera?.agreed == true && camera?.withdrawnAt == nil }

    /// The recorded movie, if there is one.
    public var recordingMovie: URL? {
        recordingFiles.map { URL(fileURLWithPath: $0) }.first { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
    }

    public var candidateTurns: [Turn] { turns.filter { $0.role == .candidate } }
    public func turn(_ id: String) -> Turn? { turns.first { $0.id == id } }

    /// Active interview time so far (pauses excluded).
    public func elapsed(now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = endedAt ?? pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
    }

    /// The time limit, with extra time when the candidate asked for it.
    public var timeLimit: TimeInterval {
        let base = TimeInterval(kit.settings.minutes * 60)
        let extra = adjustments.contains { $0.lowercased().contains("extra time") || $0.lowercased().contains("more time") }
        return extra ? base * 1.5 : base
    }

    public var isFinished: Bool { [.completed, .humanRequested, .abandoned, .expired, .withdrawn].contains(state) }

    public mutating func log(_ action: String, by who: String, detail: String = "", now: Date = Date()) {
        audit.append(AuditEntry(at: now, who: who, action: action, detail: detail))
    }
}

/// A candidate's choice about their camera: asked separately, off unless they
/// turn it on, and withdrawable at any time (the recording is then deleted).
public struct CameraConsent: Codable, Hashable, Sendable {
    public var agreed: Bool
    public var at: Date
    /// The camera wording they saw (hash).
    public var noticeHash: String
    public var withdrawnAt: Date?

    public init(agreed: Bool, at: Date, noticeHash: String, withdrawnAt: Date? = nil) {
        self.agreed = agreed
        self.at = at
        self.noticeHash = noticeHash
        self.withdrawnAt = withdrawnAt
    }
}

public struct Candidate: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
    /// The recruiter's own reference (an ATS id, say).
    public var reference: String

    public init(name: String, email: String = "", reference: String = "") {
        self.name = name
        self.email = email
        self.reference = reference
    }

    enum CodingKeys: String, CodingKey { case name, email, reference }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        reference = try c.decodeIfPresent(String.self, forKey: .reference) ?? ""
    }
}

public struct Turn: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case interviewer, candidate, system }

    public enum Kind: String, Codable, Sendable {
        case opening, eligibility, core, followUp = "follow_up", acknowledgement, rephrase, candidateQuestion = "candidate_question"
        case answer, closing, notice, other
    }

    public enum Input: String, Codable, Sendable { case typed, spoken, pasted }

    public var id: String
    public var role: Role
    public var text: String
    public var kind: Kind
    /// The core or eligibility question this belongs to.
    public var questionID: String?
    public var at: Date
    public var input: Input?

    public init(id: String, role: Role, text: String, kind: Kind, questionID: String? = nil, at: Date = Date(), input: Input? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.kind = kind
        self.questionID = questionID
        self.at = at
        self.input = input
    }

    enum CodingKeys: String, CodingKey { case id, role, text, kind, questionID = "questionId", at, input }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = (try? c.decodeIfPresent(Role.self, forKey: .role)) ?? .system
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .other
        questionID = try c.decodeIfPresent(String.self, forKey: .questionID)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        input = try? c.decodeIfPresent(Input.self, forKey: .input)
    }
}

public struct Flag: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case adjustment, humanRequested = "human_requested", distress, protectedInfoVolunteered = "protected_info_volunteered"
        case injectionAttempt = "injection_attempt", technical, offTopic = "off_topic", pasted, timeUp = "time_up", other
    }

    public var kind: Kind
    public var detail: String
    public var turn: String?
    public var at: Date

    public init(_ kind: Kind, _ detail: String, turn: String? = nil, at: Date = Date()) {
        self.kind = kind
        self.detail = detail
        self.turn = turn
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case kind, detail, turn, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .other
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        turn = try c.decodeIfPresent(String.self, forKey: .turn)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
    }

    /// How a reviewer should read it.
    public var label: String {
        switch kind {
        case .adjustment: "Adjustment requested"
        case .humanRequested: "Asked for a person"
        case .distress: "Seemed distressed"
        case .protectedInfoVolunteered: "Shared personal information (hidden from the assessment)"
        case .injectionAttempt: "Tried to instruct the AI"
        case .technical: "Technical problem"
        case .offTopic: "Off topic"
        case .pasted: "Answer pasted in (information only)"
        case .timeUp: "Ran out of time"
        case .other: "Note"
        }
    }
}

public struct AuditEntry: Codable, Hashable, Sendable {
    public var at: Date
    public var who: String
    public var action: String
    public var detail: String

    public init(at: Date, who: String, action: String, detail: String) {
        self.at = at
        self.who = who
        self.action = action
        self.detail = detail
    }
}

/// The person's decision. Only a review moves a candidate on or declines them.
public struct Review: Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable, CaseIterable {
        case advance, hold, decline

        public var label: String {
            switch self {
            case .advance: "Advance"
            case .hold: "Hold"
            case .decline: "Decline"
            }
        }
    }

    public var reviewer: String
    public var decision: Decision?
    public var reason: String
    public var note: String
    /// Levels the reviewer set, by competency id (0 = "not enough evidence").
    public var levels: [String: Int]
    public var at: Date
    /// When the candidate was told (a person sent it).
    public var candidateNotifiedAt: Date?

    public init(reviewer: String, decision: Decision? = nil, reason: String = "", note: String = "", levels: [String: Int] = [:], at: Date = Date()) {
        self.reviewer = reviewer
        self.decision = decision
        self.reason = reason
        self.note = note
        self.levels = levels
        self.at = at
    }
}
