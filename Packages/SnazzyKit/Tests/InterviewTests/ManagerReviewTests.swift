import Foundation
import Testing
@testable import Interview

/// Comparison, level changes and the next-round brief (sample kit: c1 Leading a team,
/// c2 Handling difficult customers, c3 Using data to improve; eligibility e1, e2).
@Suite struct ManagerReviewTests {
    func finished(_ name: String, kit: RoleKit, ai: [String: Int?] = [:], mine: [String: Int]? = nil,
                  decision: Review.Decision? = nil, ended: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> InterviewSession {
        var s = InterviewSession(kit: kit, candidate: Candidate(name: name), channel: .thisMac)
        s.state = .completed
        s.startedAt = ended.addingTimeInterval(-900)
        s.endedAt = ended
        if !ai.isEmpty {
            s.evaluation = Evaluation(competencies: ai.map { id, level in
                CompetencyResult(id: id, evidence: [Quote(turn: "t1", quote: "I led the rota for six people")], level: level,
                                 reason: "", probeNext: id == "c1" ? "How did you handle a disagreement in the team?" : "")
            })
        }
        if let mine { s.review = Review(reviewer: "Sam", decision: decision, reason: "Evidence meets the role's needs", levels: mine) }
        return s
    }

    // MARK: Cells

    @Test func reviewerLevelWinsOverTheAI() throws {
        let kit = try sampleKit()
        let s = finished("Ana", kit: kit, ai: ["c1": 3, "c2": nil], mine: ["c1": 4, "c3": 0])
        #expect(LevelCell.cell(s, competency: "c1") == LevelCell(level: 4, source: .reviewer))
        #expect(LevelCell.cell(s, competency: "c2") == LevelCell(level: nil, source: .ai))
        #expect(LevelCell.cell(s, competency: "c3") == LevelCell(level: nil, source: .reviewer))
        #expect(LevelCell.cell(s, competency: "c1").text == "4")
        #expect(LevelCell.cell(s, competency: "c2").text == "Not enough evidence (AI)")
        #expect(LevelCell.cell(s, competency: "c3").text == "Not enough evidence")
    }

    @Test func ratingsOffHidesTheAISuggestion() throws {
        var kit = try sampleKit()
        kit.settings.ratingsEnabled = false
        let s = finished("Ana", kit: kit, ai: ["c1": 5])
        #expect(LevelCell.cell(s, competency: "c1").source == .none)
    }

    // MARK: Audit lines

    @Test func levelChangesNameTheAISuggestionTheFirstTime() throws {
        let kit = try sampleKit()
        let eval = finished("Ana", kit: kit, ai: ["c1": 3, "c2": nil]).evaluation
        let first = ReviewLevels.changes(kit: kit, evaluation: eval, before: [:], after: ["c1": 4, "c2": 0])
        #expect(first == ["Leading a team: AI suggested 3, set to 4", "Handling difficult customers: AI suggested not enough evidence, set to not enough evidence"])
        let later = ReviewLevels.changes(kit: kit, evaluation: eval, before: ["c1": 4, "c2": 0], after: ["c1": 2, "c2": 0])
        #expect(later == ["Leading a team: 4 → 2"])
        #expect(ReviewLevels.changes(kit: kit, evaluation: eval, before: ["c1": 4], after: ["c1": 4]).isEmpty)
        #expect(ReviewLevels.changes(kit: kit, evaluation: eval, before: ["c1": 4], after: [:]) == ["Leading a team: 4 → not set"])
    }

    // MARK: Comparison

    @Test func comparisonDefaultsToNameAndLevelSortIsExplicit() throws {
        let kit = try sampleKit()
        var other = try sampleKit()
        other.id = UUID()
        var unfinished = finished("Zed", kit: kit)
        unfinished.state = .inProgress
        let sessions = [
            finished("cara", kit: kit, ai: ["c1": 2], ended: Date(timeIntervalSince1970: 1_800_000_300)),
            finished("Ben", kit: kit, ai: ["c1": 5], mine: ["c1": 3], decision: .hold, ended: Date(timeIntervalSince1970: 1_800_000_100)),
            finished("Abe", kit: kit, ai: ["c1": nil], ended: Date(timeIntervalSince1970: 1_800_000_200)),
            finished("Other role", kit: other, ai: ["c1": 5]),
            unfinished,
        ]
        let compare = RoleComparison(kitID: kit.id, competencies: kit.competencies, sessions: sessions)
        #expect(compare.rows.map(\.candidate) == ["Abe", "Ben", "cara"])
        #expect(compare.sorted(by: .date).map(\.candidate) == ["cara", "Abe", "Ben"])
        // Ben's own level (3) counts, not the AI's 5; "not enough evidence" sorts last.
        #expect(compare.sorted(by: .level("c1")).map(\.candidate) == ["Ben", "cara", "Abe"])
        #expect(compare.rows.first { $0.candidate == "Ben" }?.status == "Hold")
        #expect(compare.rows.first { $0.candidate == "Abe" }?.status == "To review")
    }

    @Test func csvMarksAILevelsAndDefusesFormulas() throws {
        let kit = try sampleKit()
        let compare = RoleComparison(kitID: kit.id, competencies: kit.competencies, sessions: [
            finished("=HYPERLINK(\"x\")", kit: kit, ai: ["c1": 4], mine: ["c2": 2]),
        ])
        let lines = compare.csv(order: compare.rows).split(separator: "\n").map(String.init)
        #expect(lines[0] == "Candidate,Interviewed,Kit version,Status,Leading a team,Handling difficult customers,Using data to improve,Flags")
        #expect(lines[1].hasPrefix("\"'=HYPERLINK(\"\"x\"\")\","))
        #expect(lines[1].contains(",4 (AI),2,–,"))
    }

    // MARK: Brief

    @Test func briefHasEvidenceProbesEligibilityAndNoHiddenDetails() throws {
        let kit = try sampleKit()
        var s = finished("Ana Diaz", kit: kit, ai: ["c1": 3], mine: ["c1": 4], decision: .advance)
        s.review?.note = "Strong on rotas.\nCheck weekend availability."
        s.eligibilityAnswers = ["e1": "Yes"]
        s.flags = [Flag(.adjustment, "extra time"), Flag(.protectedInfoVolunteered, "mentioned a health condition")]
        s.adjustments = ["extra time"]
        let md = HiringBrief.markdown(s)
        #expect(md.hasPrefix("# Ana Diaz: Customer Support Team Lead"))
        #expect(md.contains("**Advance** by Sam"))
        #expect(md.contains("> Strong on rotas.\n> Check weekend availability."))
        #expect(md.contains("- **Leading a team:** How did you handle a disagreement in the team?"))
        #expect(md.contains("### Leading a team (35%): reviewer: 4, AI suggested: 3"))
        #expect(md.contains("- “I led the rota for six people”"))
        #expect(md.contains("**Yes**"))
        #expect(md.contains("Adjustment asked for: extra time"))
        #expect(!md.contains("health"))
        #expect(!md.lowercased().contains("personal information"))
    }

    @Test func briefWithRatingsOffShowsNoLevels() throws {
        var kit = try sampleKit()
        kit.settings.ratingsEnabled = false
        let md = HiringBrief.markdown(finished("Ana", kit: kit, ai: ["c1": 3], mine: ["c1": 4]))
        #expect(md.contains("### Leading a team (35%)\n"))
        #expect(!md.contains("AI suggested"))
    }
}
