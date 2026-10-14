import Foundation

/// The interviewer, evaluator and kit-generator prompts (Resources/prompts,
/// shared with OpsAPI), filled in for a kit or an interview.
public enum InterviewPrompts {
    public static let interviewerVersion = "interviewer.v1"
    public static let evaluatorVersion = Evaluator.promptVersion
    public static let kitGeneratorVersion = "kit-generator.v1"

    public static func template(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "prompts")
            ?? Bundle.module.url(forResource: name, withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Prompt \(name).md is missing from the Interview bundle")
        }
        return text
    }

    /// Replaces each {{key}}; unknown keys are left as they are.
    public static func render(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (key, value) in values { out = out.replacingOccurrences(of: "{{\(key)}}", with: value) }
        return out
    }

    // MARK: Interviewer

    public static func interviewerSystem(for kit: RoleKit, voice: Bool) -> String {
        render(template(interviewerVersion), [
            "organisation": kit.organisation.isEmpty ? "the hiring organisation" : kit.organisation,
            "role_title": kit.title,
            "interviewer_name": kit.settings.interviewerName,
            "role_summary": kit.summary.isEmpty ? kit.title : kit.summary,
            "competencies": kit.competencies.map { "- \($0.id): \($0.name). \($0.description)" }.joined(separator: "\n"),
            "next_steps": kit.settings.nextSteps,
            "allowed_adjustments": kit.settings.allowedAdjustments.joined(separator: ", "),
            "company_facts": kit.companyFacts.trimmed.isEmpty ? "(none given)" : kit.companyFacts,
            "style": voice
                ? "You are speaking aloud: short sentences, no lists, no symbols or markdown, no links."
                : "Plain text, no markdown.",
            "language": kit.language,
        ])
    }

    /// The user message for one interviewer call: the transcript so far, then the engine's directive.
    public static func interviewerMessage(for session: InterviewSession, directive: String) -> String {
        let transcript = session.turns.compactMap { turn -> String? in
            switch turn.role {
            case .system: nil
            case .interviewer: "[\(turn.id)] Interviewer: \(turn.text)"
            case .candidate: "[\(turn.id)] Candidate:\n<external_data turn=\"\(turn.id)\">\n\(turn.text)\n</external_data>"
            }
        }.joined(separator: "\n\n")
        return "<transcript>\n\(transcript)\n</transcript>\n\n<engine>\n\(directive)\n</engine>"
    }

    // MARK: Evaluator

    public static func evaluatorPrompt(for session: InterviewSession) -> String {
        let kit = session.kit
        let rubric = kit.competencies.map { c in
            """
            Competency \(c.id): \(c.name). \(c.description)
              Level 1: \(c.anchors.level1)
              Level 3: \(c.anchors.level3)
              Level 5: \(c.anchors.level5)
              (2 and 4 fall between their neighbours.)
            """
        }.joined(separator: "\n")
        return render(template(evaluatorVersion), [
            "role_title": kit.title,
            "rubric": rubric,
            "transcript": Evaluator.transcript(for: session),
            "written_communication_rule": kit.settings.writtenCommunication
                ? " (except for a written-communication competency, judged only against its anchors)"
                : "",
        ])
    }

    // MARK: Kit generator

    public static func kitGeneratorPrompt(jobDescription: String, language: String = "en-GB") -> String {
        render(template(kitGeneratorVersion), ["job_description": jobDescription, "language": language])
    }

    /// Reads the generator's JSON into a draft kit (unapproved).
    public static func parseGeneratedKit(_ text: String, jobDescription: String, now: Date = Date()) -> RoleKit? {
        guard let json = ModelJSON.firstObject(in: text),
              var kit = try? InterviewJSON.decoder.decode(RoleKit.self, from: Data(json.utf8)) else { return nil }
        guard !kit.competencies.isEmpty, !kit.questions.isEmpty else { return nil }
        kit.id = UUID()
        kit.version = 0
        kit.approvedAt = nil
        kit.approvedBy = nil
        kit.jobDescription = jobDescription
        kit.created = now
        kit.updated = now
        kit.format = RoleKit.formatVersion
        return kit
    }

    // MARK: Candidate notice

    /// What a candidate reads before starting. `provider` names who runs the AI
    /// ("Anthropic (Claude)", "a model on the recruiter's computer").
    public static func notice(for kit: RoleKit, provider: String) -> String {
        let org = kit.organisation.isEmpty ? "the hiring team" : kit.organisation
        return """
        This is a first-round interview for \(kit.title) with \(org). The interviewer is an AI, not a person.

        What happens: the AI asks every candidate for this role the same main questions in the same order, and may ask \
        short follow-up questions about your answers. It takes about \(kit.settings.minutes) minutes. You can ask for any \
        question to be repeated or rephrased\(kit.settings.allowPause ? ", and you can pause" : ""). At the end you can ask your own questions.

        Who decides: a person at \(org) reads your answers and makes the decision. The AI does not decide, rank or reject \
        anyone. After the interview, the AI summarises the evidence in your answers against the skills the role needs; \
        the hiring team sees your answers alongside that summary.

        What is not used: the AI does not analyse your face, voice, tone, emotions or typing. Only the words of your \
        answers are assessed. Personal details you mention (for example about health, family or religion) are hidden from \
        the assessment.

        Your data: your answers are processed by \(provider) and kept by \(org) for up to \(kit.settings.retentionDays) days \
        after a decision, then deleted. You can ask \(org) for a copy, a correction or deletion at any time.

        Adjustments: tell us below if you need extra time, a pause, text instead of voice or anything else. Asking won't \
        count against you.

        If you'd rather speak to a person instead, choose "I'd prefer to speak to a person". That won't count against you either.
        """
    }

    /// The camera choice, shown apart from the notice when the camera is offered.
    public static func cameraNotice(for kit: RoleKit) -> String {
        let org = kit.organisation.isEmpty ? "the hiring team" : kit.organisation
        return """
        You can choose to turn your camera on. If you do, this interview is recorded (your camera, your microphone and \
        the slides) so people on the hiring team at \(org) can watch it. The recording is never analysed by AI: not your \
        face, your voice, your expressions or your surroundings. It is kept with your interview for up to \
        \(kit.settings.retentionDays) days after a decision, then deleted, and you can ask for it to be deleted sooner. \
        Leaving the camera off is completely fine and won't count against you. You can turn it off at any time, and \
        the recording is then deleted.
        """
    }

    /// A short, stable hash of the notice text, stored with the acknowledgement.
    public static func hash(_ text: String) -> String {
        // FNV-1a, 64-bit: enough to show which wording was shown.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", h)
    }
}
