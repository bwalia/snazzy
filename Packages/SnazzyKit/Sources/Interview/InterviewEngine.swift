import Foundation

/// The steps of an interview, fixed by the kit: eligibility questions, then core
/// questions in kit order, then the candidate's questions, then closing.
public enum InterviewStep: Hashable, Sendable {
    case eligibility(EligibilityQuestion)
    case core(CoreQuestion)
    case candidateQuestions
    case closing

    public static func plan(for kit: RoleKit) -> [InterviewStep] {
        kit.eligibility.map { .eligibility($0) } + kit.questions.map { .core($0) } + [.candidateQuestions, .closing]
    }
}

/// What the interviewer model replied (JSON; see interviewer.v1.md).
public struct InterviewerReply: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        case followUp = "follow_up", moveOn = "move_on", rephrase, answer, forward, done, end
    }

    public struct ReplyFlag: Codable, Hashable, Sendable {
        public var kind: String
        public var detail: String

        public init(kind: String, detail: String) {
            self.kind = kind
            self.detail = detail
        }
    }

    public var action: Action
    public var say: String
    public var enoughEvidence: Bool?
    public var flags: [ReplyFlag]

    public init(action: Action, say: String, enoughEvidence: Bool? = nil, flags: [ReplyFlag] = []) {
        self.action = action
        self.say = say
        self.enoughEvidence = enoughEvidence
        self.flags = flags
    }

    enum CodingKeys: String, CodingKey { case action, say, enoughEvidence, flags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(Action.self, forKey: .action)
        say = try c.decodeIfPresent(String.self, forKey: .say) ?? ""
        enoughEvidence = try c.decodeIfPresent(Bool.self, forKey: .enoughEvidence)
        flags = try c.decodeIfPresent([ReplyFlag].self, forKey: .flags) ?? []
    }

    /// Reads the reply from model text: the first JSON object in it.
    public static func parse(_ text: String) -> InterviewerReply? {
        guard let json = ModelJSON.firstObject(in: text) else { return nil }
        return try? InterviewJSON.decoder.decode(InterviewerReply.self, from: Data(json.utf8))
    }
}

/// What the candidate (or their page) did.
public enum CandidateEvent: Hashable, Sendable {
    case answer(String, input: Turn.Input)
    case repeatQuestion
    case rephraseQuestion
    case pause
    case resume
    case askForPerson
    case withdraw
    case adjustment(String)
}

/// Runs an interview. The engine owns the order, the timing and the end; the
/// model only chooses follow-ups and their wording, and the engine checks what
/// it says. Pure and synchronous: the caller runs the model when asked to.
public struct InterviewEngine: Sendable {
    public private(set) var session: InterviewSession
    public let steps: [InterviewStep]
    var now: @Sendable () -> Date

    public init(session: InterviewSession, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.steps = InterviewStep.plan(for: session.kit)
        self.now = now
    }

    /// What the caller should do next.
    public enum Next: Equatable, Sendable {
        /// Wait for the candidate.
        case waitForCandidate
        /// Ask the interviewer model; pass its reply to `apply(_:)`.
        case askModel(directive: String)
        /// The interview is over.
        case finished
    }

    public var currentStep: InterviewStep? { steps.indices.contains(session.step) ? steps[session.step] : nil }

    /// What the candidate is answering now, for their page.
    public var currentQuestionID: String? {
        switch currentStep {
        case .eligibility(let q): q.id
        case .core(let q): q.id
        default: nil
        }
    }

    /// Fixed choices for the current question (eligibility), if any.
    public var currentChoices: [String]? {
        if case .eligibility(let q) = currentStep { return q.choices }
        return nil
    }

    /// Progress through the core and eligibility questions (0…1).
    public var progress: Double {
        let total = max(1, steps.count - 2)
        return min(1, Double(session.step) / Double(total))
    }

    public var secondsLeft: TimeInterval { max(0, session.timeLimit - session.elapsed(now: now())) }

    // MARK: Starting

    /// Records that the candidate read the notice and agreed, with any adjustments.
    public mutating func acknowledge(noticeHash: String, adjustments: [String]) {
        let t = now()
        session.noticeHash = noticeHash
        session.noticeAcceptedAt = t
        for a in adjustments where !a.trimmed.isEmpty {
            session.adjustments.append(a)
            session.flags.append(Flag(.adjustment, a, at: t))
        }
        session.log("notice_acknowledged", by: "candidate", now: t)
    }

    /// The candidate's camera choice (only when the camera is offered).
    public mutating func setCamera(_ agreed: Bool) {
        guard session.cameraOffered else { return }
        let t = now()
        let wording = InterviewPrompts.cameraNotice(for: session.kit)
        session.camera = CameraConsent(agreed: agreed, at: t, noticeHash: InterviewPrompts.hash(wording))
        session.log(agreed ? "camera_on" : "camera_declined", by: "candidate", now: t)
    }

    /// The candidate turned the camera off: consent is withdrawn (the caller deletes the recording).
    public mutating func withdrawCamera() {
        guard session.cameraAgreed else { return }
        let t = now()
        session.camera?.withdrawnAt = t
        session.log("camera_withdrawn", by: "candidate", now: t)
    }

    /// The candidate asked for a person instead, before starting: no interview, just the request.
    public mutating func requestPersonBeforeStart() {
        guard session.state == .invited else { return }
        session.flags.append(Flag(.humanRequested, "Asked for a person before starting", at: now()))
        finish(.humanRequested, reason: "human_requested")
    }

    /// Starts: the opening words and the first question.
    public mutating func start() -> Next {
        guard session.state == .invited else { return session.isFinished ? .finished : .waitForCandidate }
        let t = now()
        session.state = .inProgress
        session.startedAt = t
        session.step = 0
        session.followUps = 0
        let kit = session.kit
        let name = session.candidate.name.split(separator: " ").first.map(String.init) ?? ""
        let hello = name.isEmpty ? "Hello" : "Hello \(name)"
        let opening = """
        \(hello), and thank you for your time. I'm \(kit.settings.interviewerName), an AI interviewer for \
        \(kit.organisation.isEmpty ? "the hiring team" : kit.organisation), and this is a first-round interview for \
        \(kit.title). I'll ask \(kit.questions.count) main questions\(kit.eligibility.isEmpty ? "" : ", after a few quick ones about the role's requirements"), \
        and you can ask me questions at the end. Take your time; you can ask me to repeat or rephrase any question. \
        A person on the hiring team reviews everything and makes the decision.
        """
        append(.interviewer, opening, .opening)
        session.log("started", by: "engine", now: t)
        askCurrent()
        return .waitForCandidate
    }

    // MARK: Candidate events

    public mutating func receive(_ event: CandidateEvent) -> Next {
        if session.isFinished { return .finished }
        if case .resume = event {} else if session.state == .paused { return .waitForCandidate }
        let t = now()
        switch event {
        case .answer(let raw, let input):
            let text = String(raw.trimmed.prefix(Self.maxAnswerLength))
            guard !text.isEmpty else { return .waitForCandidate }
            let turn = append(.candidate, text, kindForAnswer, questionID: currentQuestionID, input: input)
            if input == .pasted { session.flags.append(Flag(.pasted, "", turn: turn.id, at: t)) }
            for topic in BannedTopics.find(in: text) {
                session.flags.append(Flag(.protectedInfoVolunteered, topic, turn: turn.id, at: t))
            }
            return afterAnswer(text)
        case .repeatQuestion:
            if let q = lastAsked { append(.interviewer, q.text, q.kind, questionID: q.questionID) }
            return .waitForCandidate
        case .rephraseQuestion:
            guard let q = lastAsked, q.kind == .core || q.kind == .followUp else {
                if let q = lastAsked { append(.interviewer, q.text, q.kind, questionID: q.questionID) }
                return .waitForCandidate
            }
            return .askModel(directive: directive(rephrase: q.text))
        case .pause:
            guard session.kit.settings.allowPause || session.adjustments.contains(where: { $0.lowercased().contains("pause") }) else {
                return .waitForCandidate
            }
            session.state = .paused
            session.pausedAt = t
            session.log("paused", by: "candidate", now: t)
            return .waitForCandidate
        case .resume:
            if session.state == .paused, let p = session.pausedAt {
                session.pausedSeconds += t.timeIntervalSince(p)
                session.pausedAt = nil
                session.state = .inProgress
                session.log("resumed", by: "candidate", now: t)
                if let q = lastAsked { append(.interviewer, "Welcome back. " + q.text, q.kind, questionID: q.questionID) }
            }
            return .waitForCandidate
        case .askForPerson:
            session.flags.append(Flag(.humanRequested, "Asked to speak to a person", at: t))
            append(.interviewer, "Of course. I've let the hiring team know you'd like to speak to a person, and they'll be in touch. This won't count against you. Thank you.", .closing)
            finish(.humanRequested, reason: "human_requested")
            return .finished
        case .withdraw:
            append(.system, "The candidate withdrew.", .other)
            finish(.withdrawn, reason: "withdrawn")
            return .finished
        case .adjustment(let what):
            session.adjustments.append(what)
            session.flags.append(Flag(.adjustment, what, at: t))
            let granted = session.kit.settings.allowedAdjustments.contains { what.lowercased().contains($0.lowercased()) }
            append(.interviewer, granted
                   ? "Of course, that's fine. Let's carry on whenever you're ready."
                   : "Thank you for telling me. I've passed that to the hiring team. We can carry on now, or stop and let them arrange something else; just say which.", .other)
            return .waitForCandidate
        }
    }

    /// Call regularly: moves on when time runs out.
    public mutating func tick() -> Next {
        guard session.state == .inProgress, secondsLeft <= 0 else { return session.isFinished ? .finished : .waitForCandidate }
        guard let step = currentStep else { return .finished }
        switch step {
        case .eligibility, .core:
            session.flags.append(Flag(.timeUp, "Time ran out at question \(currentQuestionID ?? "")", at: now()))
            session.step = steps.firstIndex(of: .closing) ?? steps.count - 1
            close()
            return .finished
        case .candidateQuestions:
            session.step += 1
            close()
            return .finished
        case .closing:
            close()
            return .finished
        }
    }

    // MARK: The model's reply

    /// Applies the interviewer model's reply (nil if it failed or wasn't valid JSON).
    public mutating func apply(_ reply: InterviewerReply?, rawText: String = "") -> Next {
        guard session.state == .inProgress, let step = currentStep else { return session.isFinished ? .finished : .waitForCandidate }
        let t = now()
        let lastCandidate = session.turns.last(where: { $0.role == .candidate })?.id
        for f in reply?.flags ?? [] {
            let kind = Flag.Kind(rawValue: f.kind) ?? .other
            // Personal topics come only from the engine's own screen of each answer
            // (`receive`): models over-report them, and a true one is already flagged.
            if kind == .protectedInfoVolunteered { continue }
            // The engine records requests for a person itself, from the candidate's own words.
            session.flags.append(Flag(kind, String(f.detail.prefix(200)), turn: lastCandidate, at: t))
        }
        if reply == nil, !rawText.isEmpty {
            session.flags.append(Flag(.technical, "The interviewer's reply couldn't be read; moved on.", at: t))
        }

        if let reply, reply.action == .rephrase, let asked = lastAsked {
            let text = Guard.question(reply.say) ?? asked.text
            append(.interviewer, text, .rephrase, questionID: asked.questionID)
            return .waitForCandidate
        }

        switch step {
        case .core:
            if let reply, reply.action == .followUp, session.followUps < session.kit.settings.maxFollowUps,
               secondsLeft > 60, let question = Guard.question(reply.say) {
                session.followUps += 1
                append(.interviewer, question, .followUp, questionID: currentQuestionID)
                return .waitForCandidate
            }
            let ack = Guard.acknowledgement(reply?.say ?? "")
            advance(ack: ack)
            return session.isFinished ? .finished : .waitForCandidate
        case .candidateQuestions:
            let asked = session.turns.filter { $0.kind == .candidateQuestion && $0.role == .candidate }.count
            let more = asked < Self.maxCandidateQuestions ? " Do you have any other questions?" : ""
            switch reply?.action {
            case .answer? where Guard.isGrounded(reply!.say, in: session.kit.companyFacts):
                append(.interviewer, Guard.answer(reply!.say) + more, .answer)
            case .answer?, .forward?:
                // An answer the company facts don't support is never given: it goes to the team.
                if reply?.action == .answer {
                    session.flags.append(Flag(.other, "The interviewer's answer wasn't in the company facts; the question was passed on instead.", at: t))
                }
                if let q = session.turns.last(where: { $0.role == .candidate })?.text { session.forwardedQuestions.append(q) }
                append(.interviewer, "I don't have that information, so I've passed your question to the hiring team." + (more.isEmpty ? "" : " Is there anything else you'd like to ask?"), .answer)
            default:
                session.step += 1
                close()
                return .finished
            }
            if more.isEmpty {
                session.step += 1
                close()
                return .finished
            }
            return .waitForCandidate
        case .eligibility, .closing:
            return .waitForCandidate
        }
    }

    // MARK: Directives for the model

    /// The engine's instruction for the current point, appended to the transcript.
    func directive(rephrase: String? = nil) -> String {
        let minutes = Int(secondsLeft / 60)
        if let rephrase {
            return """
            The candidate asked for the question to be rephrased. Reply with action "rephrase" and, in "say", one plainer \
            wording of this question with the same meaning and no hints: "\(rephrase)"
            """
        }
        switch currentStep {
        case .core(let q):
            let c = session.kit.competency(q.competency)
            return """
            Phase: core question \(q.id) for competency \(q.competency) (\(c?.name ?? "")). Follow-ups used: \
            \(session.followUps) of \(session.kit.settings.maxFollowUps). Minutes left: \(minutes). Decide on the \
            candidate's last answer: "follow_up" with one short neutral question, or "move_on" with a short neutral \
            acknowledgement (no question; the engine asks the next question).
            """
        case .candidateQuestions:
            return """
            Phase: candidate questions. Minutes left: \(minutes). If the candidate asked something the company facts \
            answer, reply "answer". If the facts don't answer it, reply "forward". If they have no (more) questions, reply "done".
            """
        default:
            return "No reply is needed."
        }
    }

    // MARK: Internals

    static let maxAnswerLength = 6000
    /// Candidate questions answered before closing.
    static let maxCandidateQuestions = 3

    private var kindForAnswer: Turn.Kind {
        if case .candidateQuestions = currentStep { return .candidateQuestion }
        return .answer
    }

    private var lastAsked: Turn? {
        session.turns.last { $0.role == .interviewer && [.eligibility, .core, .followUp, .rephrase].contains($0.kind) }
    }

    private mutating func afterAnswer(_ text: String) -> Next {
        switch currentStep {
        case .eligibility(let q):
            session.eligibilityAnswers[q.id] = text
            advance(ack: "Thank you.")
            return session.isFinished ? .finished : .waitForCandidate
        case .core:
            if secondsLeft <= 0 { return tick() }
            return .askModel(directive: directive())
        case .candidateQuestions:
            if Guard.saysNoMoreQuestions(text) {
                session.step += 1
                close()
                return .finished
            }
            return .askModel(directive: directive())
        case .closing, nil:
            return .finished
        }
    }

    private mutating func advance(ack: String) {
        session.step += 1
        session.followUps = 0
        if secondsLeft <= 0, case .core = currentStep { _ = tick(); return }
        askCurrent(prefix: ack)
    }

    private mutating func askCurrent(prefix: String = "") {
        let lead = prefix.isEmpty ? "" : prefix + " "
        switch currentStep {
        case .eligibility(let q):
            append(.interviewer, lead + q.text, .eligibility, questionID: q.id)
        case .core(let q):
            append(.interviewer, lead + q.text, .core, questionID: q.id)
        case .candidateQuestions:
            append(.interviewer, lead + "That's all my questions. Do you have any questions for me about the role or the process?", .candidateQuestion)
        case .closing:
            close()
        case nil:
            break
        }
    }

    private mutating func close() {
        guard !session.isFinished else { return }
        append(.interviewer, "Thank you for your time today. \(session.kit.settings.nextSteps)", .closing)
        finish(.completed, reason: "completed")
    }

    private mutating func finish(_ state: InterviewSession.State, reason: String) {
        let t = now()
        if session.state == .paused, let p = session.pausedAt { session.pausedSeconds += t.timeIntervalSince(p) }
        session.pausedAt = nil
        session.state = state
        session.endedAt = t
        session.endReason = reason
        session.deleteAfter = Calendar.current.date(byAdding: .day, value: max(session.kit.settings.retentionDays, 1), to: t)
        session.log("ended", by: "engine", detail: reason, now: t)
    }

    @discardableResult
    private mutating func append(_ role: Turn.Role, _ text: String, _ kind: Turn.Kind, questionID: String? = nil, input: Turn.Input? = nil) -> Turn {
        let turn = Turn(id: "t\(session.turns.count + 1)", role: role, text: text, kind: kind, questionID: questionID, at: now(), input: input)
        session.turns.append(turn)
        return turn
    }
}

/// Checks on what the interviewer model says, so a bad reply can't lead, praise,
/// rate, or raise a banned topic.
enum Guard {
    static let praise = [
        "great", "excellent", "impressive", "perfect", "fantastic", "brilliant", "amazing", "outstanding", "awesome",
        "good answer", "well done", "strong answer", "nice", "wonderful", "love that", "exactly right", "spot on",
        "not quite", "that's wrong", "that is wrong", "disappointing", "your score", "you scored", "your rating",
        "i'd rate", "i would rate", "rubric", "you'll get the job", "you will get the job", "you're hired",
    ]

    /// A follow-up or rephrased question: one short question, neutral, on topic; nil if unusable.
    static func question(_ text: String) -> String? {
        var t = text.trimmed.replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty, t.count <= 400, t.contains("?") else { return nil }
        t = dropSentences(containing: praise, from: t)
        guard t.contains("?"), BannedTopics.find(in: t).isEmpty else { return nil }
        return t
    }

    /// A neutral acknowledgement with no question in it.
    static func acknowledgement(_ text: String) -> String {
        let t = dropSentences(containing: praise, from: text.trimmed.replacingOccurrences(of: "\n", with: " "))
        guard !t.isEmpty, t.count <= 160, !t.contains("?"), BannedTopics.find(in: t).isEmpty else { return "Thank you." }
        return t
    }

    /// An answer to a candidate's question, kept short.
    static func answer(_ text: String) -> String {
        let t = text.trimmed
        guard !t.isEmpty else { return "I don't have that information, so I've passed your question to the hiring team." }
        return String(t.prefix(800))
    }

    /// Whether an answer to a candidate's question comes from the company facts:
    /// most of its meaningful words must appear there.
    static func isGrounded(_ answer: String, in facts: String) -> Bool {
        let factWords = Set(words(facts))
        let answerWords = words(answer)
        guard !factWords.isEmpty, !answerWords.isEmpty else { return false }
        let found = answerWords.filter { factWords.contains($0) }.count
        return Double(found) / Double(answerWords.count) >= 0.6
    }

    static let stopWords: Set<String> = [
        "about", "after", "also", "been", "before", "being", "between", "both", "could", "does", "each", "from", "have", "here",
        "into", "just", "like", "more", "most", "much", "only", "other", "over", "same", "should", "some", "such", "than",
        "that", "their", "them", "then", "there", "these", "they", "this", "those", "through", "very", "what", "when", "where",
        "which", "while", "will", "with", "would", "your", "yours", "role", "team", "great", "question", "thanks", "thank",
        "happy", "glad", "information", "know", "share", "help", "really", "well", "we're", "you're", "it's", "there's",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "£" && $0 != "$" && $0 != "%" }
            .map(String.init).filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    static func saysNoMoreQuestions(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        let none = ["no", "nope", "no thanks", "no thank you", "none", "nothing", "not really", "no questions",
                    "no, thank you", "no, thanks", "i'm good", "im good", "that's all", "thats all", "no that's all"]
        return none.contains(t)
    }

    static func dropSentences(containing words: [String], from text: String) -> String {
        var kept: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sub, _, _, _ in
            guard let sub else { return }
            let lower = sub.lowercased()
            let hit = words.contains { w in
                lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: w), options: .regularExpression) != nil
            }
            if !hit { kept.append(sub.trimmed) }
        }
        return kept.joined(separator: " ")
    }
}

/// Finds JSON in model output (models sometimes wrap it in prose or code fences).
public enum ModelJSON {
    public static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
