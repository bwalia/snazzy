import Foundation
import SnazzyCore

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

/// A shareable prep pack: an ordinary zip (`.snazzyprep`) holding one or more
/// prep kits as `<slug>/prep-kit.json`. Free and open: no passcode, no
/// encryption, so it can go by AirDrop, email, chat or a web link.
public enum PrepPack {
    public static let fileExtension = "snazzyprep"
    /// Big enough for many kits; prep packs are text.
    static let maxBytes = 20 << 20

    /// A zip of the kits, with a short README for people who unzip it by hand.
    public static func archive(_ kits: [PrepKit]) throws -> Data {
        var entries = try kits.map { kit in
            Zip.Entry(path: "\(kit.slug)/prep-kit.json", data: try InterviewJSON.encoder.encode(kit))
        }
        entries.append(Zip.Entry(path: "README.txt", data: Data("""
        Snazzy Pro interview prep pack: \(kits.map(\.role).joined(separator: ", ")).

        Open this file with Snazzy Pro (https://snazzy.pro) to study the topics, do the
        hands-on exercises and practise the interview with your own AI model. Free.
        """.utf8)))
        return try Zip.archive(entries)
    }

    /// The prep kits in a `.snazzyprep` or `.zip` (every `prep-kit.json` or other
    /// `.json` prep kit inside, e.g. the repo's `prep-kits` folder), or a single
    /// prep kit JSON file. Kits whose practice interview breaks the interview
    /// rules (e.g. a question on a banned topic) are refused.
    public static func read(_ data: Data) throws -> [PrepKit] {
        guard data.count <= maxBytes else { throw InterviewFileError("This prep pack is too big (20 MB at most).") }
        let files: [Data]
        if Zip.isZip(data) {
            files = try Zip.entries(data, limit: maxBytes).filter { $0.path.lowercased().hasSuffix(".json") }.map(\.data)
        } else {
            files = [data]
        }
        var kits: [PrepKit] = []
        for file in files {
            guard let kit = try? PrepKit.decode(file) else { continue }
            guard KitValidator.canApprove(kit.practice) else {
                throw InterviewFileError("The prep kit “\(kit.role)” has a practice interview that breaks the interview rules, so it wasn't added.")
            }
            guard Zip.isSafePath(kit.slug), !kit.slug.contains("/") else { throw InterviewFileError("The prep kit “\(kit.role)” has an unusable name.") }
            if !kits.contains(where: { $0.slug == kit.slug }) { kits.append(kit) }
        }
        guard !kits.isEmpty else { throw InterviewFileError("There's no Snazzy prep kit in this file.") }
        return kits
    }
}
