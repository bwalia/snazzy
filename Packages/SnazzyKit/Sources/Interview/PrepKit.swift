import Foundation

/// A free interview prep kit for candidates (`prep-kits/<slug>/prep-kit.json`):
/// topics to study (with official links), hands-on exercises to do in your own
/// editor and record as a walkthrough, and a practice interview. Practice runs
/// on the candidate's own AI model, and its feedback is for them alone.
public struct PrepKit: Codable, Hashable, Sendable, Identifiable {
    public static let format = "snazzy-prep-kit"

    public struct Link: Codable, Hashable, Sendable {
        public var title: String
        public var url: String
    }

    public struct Topic: Codable, Hashable, Sendable, Identifiable {
        public var title: String
        public var why: String
        public var points: [String]
        public var links: [Link]
        public var id: String { title }
    }

    public struct Exercise: Codable, Hashable, Sendable, Identifiable {
        public var title: String
        public var goal: String
        public var steps: [String]
        /// Worth recording as a screen-and-camera walkthrough.
        public var record: Bool
        public var id: String { title }
    }

    public var format: String
    public var version: Int
    public var slug: String
    public var role: String
    public var summary: String
    public var updated: String
    public var topics: [Topic]
    public var exercises: [Exercise]
    /// The practice interview: an approved kit, run on the candidate's own model.
    public var practice: RoleKit

    public var id: String { slug }

    public static func decode(_ data: Data) throws -> PrepKit {
        let kit = try InterviewJSON.decoder.decode(PrepKit.self, from: data)
        guard kit.format == format else { throw InterviewFileError("This isn't a Snazzy prep kit.") }
        return kit
    }

    /// A study deck: the role, then one slide per topic (its points on the slide,
    /// why it matters in the notes), then the exercises.
    public var studySlides: [(heading: String, items: [String], notes: String)] {
        var slides: [(String, [String], String)] = [(role, ["Interview prep"], summary)]
        for t in topics { slides.append((t.title, t.points, t.why)) }
        slides.append(("Learn by doing", exercises.map(\.title), "Do each exercise in your own editor and record a short walkthrough."))
        return slides
    }
}

/// Coaching after a practice interview: unlike hiring, the feedback is for the
/// candidate, so it can say what a strong answer covers.
public enum Coaching {
    public struct Item: Hashable, Sendable {
        public var competency: String
        public var level: Int?
        public var heard: [String]
        public var strongAnswer: String
        public var nextTime: String
    }

    public static func items(for session: InterviewSession) -> [Item] {
        guard let e = session.evaluation else { return [] }
        return session.kit.competencies.map { c in
            let r = e.result(c.id)
            return Item(competency: c.name, level: r?.level, heard: r?.evidence.map(\.quote) ?? [],
                        strongAnswer: c.anchors.level5,
                        nextTime: r?.probeNext.isEmpty == false ? r!.probeNext : "Give a specific example: what you did, why, and the result.")
        }
    }
}
