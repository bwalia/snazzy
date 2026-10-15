import Foundation
import SnazzyCore

/// What the candidate's page is shown: only the conversation and what they
/// need to answer, never flags, evaluations or anything about the rubric.
public enum CandidateState {
    public static func json(for engine: InterviewEngine, busy: Bool, provider: String, selfIDDone: Bool, now: Date = Date()) -> JSONValue {
        let s = engine.session
        let kit = s.kit
        if let expires = s.linkExpires, expires < now, s.state == .invited { return ["phase": "expired"] }
        let notice = InterviewPrompts.notice(for: kit, provider: provider)
        let phase: String = switch s.state {
        case .invited: "notice"
        case .inProgress: "interview"
        case .paused: "paused"
        case .withdrawn: "invalid"
        default: "finished"
        }
        var out: [String: JSONValue] = [
            "phase": .string(phase),
            "title": .string(kit.title),
            "organisation": .string(kit.organisation),
            "interviewer_name": .string(kit.settings.interviewerName),
            "allow_pause": .bool(kit.settings.allowPause),
        ]
        switch phase {
        case "notice":
            out["notice"] = .string(notice)
            out["notice_hash"] = .string(InterviewPrompts.hash(notice))
            out["adjustments_offered"] = .array(kit.settings.allowedAdjustments.map { .string($0) })
        case "interview", "paused":
            out["turns"] = .array(s.turns.filter { $0.role != .system }.map {
                ["id": .string($0.id), "role": .string($0.role.rawValue), "text": .string($0.text)]
            })
            out["choices"] = engine.currentChoices.map { .array($0.map { .string($0) }) } ?? .null
            out["progress"] = .number(engine.progress)
            out["seconds_left"] = .number(engine.secondsLeft.rounded())
            out["busy"] = .bool(busy)
        case "finished":
            out["closing"] = .string(s.turns.last { $0.role == .interviewer }?.text ?? "Your interview is complete.")
            out["end_reason"] = .string(s.endReason ?? "")
            out["self_id"] = s.state == .completed || s.state == .humanRequested
                ? .array(SelfID.questions.map { q in
                    ["id": .string(q.id), "label": .string(q.label), "options": .array(q.options.map { .string($0) })]
                })
                : .null
            out["self_id_done"] = .bool(selfIDDone)
        default:
            break
        }
        return .object(out)
    }
}
