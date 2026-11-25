import Foundation

/// A voice note: something said out loud (a thought while talking, a brainstorm,
/// a meeting), kept as audio plus the words, turned into text on the device that
/// recorded it. Shared by the Mac, iPhone/iPad and Windows/Linux apps
/// (`docs/specs/voice-notes.md`): each note is a folder holding `note.json` and
/// the audio file.
public struct VoiceNote: Codable, Sendable, Equatable, Identifiable {
    public static let format = "snazzy-voice-note"
    public static let fileName = "note.json"

    /// A stretch of speech with its time in the audio (seconds).
    public struct Segment: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// A moment marked while talking ("that's a good idea"), seconds into the audio.
    public struct Mark: Codable, Sendable, Equatable {
        public var at: Double
        public var label: String

        public init(at: Double, label: String = "Idea") {
            self.at = at
            self.label = label
        }
    }

    public var format: String
    public var version: Int
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Length of the audio in seconds (0 for a note with no audio).
    public var duration: Double
    /// The audio file's name in the note's folder (`audio.m4a`, `audio.webm`…), if kept.
    public var audio: String?
    /// The whole text: the segments joined, or typed/edited by hand.
    public var transcript: String
    public var segments: [Segment]
    public var marks: [Mark]
    public var tags: [String]
    /// Where it was recorded: `Mac`, `iPhone`, `iPad`, `Windows`, `Linux`.
    public var device: String
    /// The speech language, e.g. `en-GB`.
    public var language: String?
    /// How the text was made: `on-device`, `whisper-server`, `typed`, or `none` (audio only).
    public var transcribedBy: String

    enum CodingKeys: String, CodingKey {
        case format, version, id, title, duration, audio, transcript, segments, marks, tags, device, language
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case transcribedBy = "transcribed_by"
    }

    public init(id: String = UUID().uuidString.lowercased(), title: String = "", createdAt: Date = Date(),
                duration: Double = 0, audio: String? = nil, transcript: String = "", segments: [Segment] = [],
                marks: [Mark] = [], tags: [String] = [], device: String, language: String? = nil,
                transcribedBy: String = "on-device") {
        format = Self.format
        version = 1
        self.id = id
        self.title = title
        self.createdAt = createdAt
        updatedAt = createdAt
        self.duration = duration
        self.audio = audio
        self.transcript = transcript
        self.segments = segments
        self.marks = marks
        self.tags = tags
        self.device = device
        self.language = language
        self.transcribedBy = transcribedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? Self.format
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language)
        transcribedBy = try c.decodeIfPresent(String.self, forKey: .transcribedBy) ?? "none"
    }

    /// The title to show: the one given, else the first words said, else the date.
    public var displayTitle: String {
        let given = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { return given }
        let derived = Self.title(from: transcript)
        if !derived.isEmpty { return derived }
        return "Voice note, " + createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// A short title from the first words said (up to 7 words, no trailing punctuation).
    public static func title(from text: String) -> String {
        let firstSentence = text.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? ""
        let words = firstSentence.split(whereSeparator: \.isWhitespace).prefix(7)
        guard !words.isEmpty else { return "" }
        var title = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        if let first = title.first { title = first.uppercased() + title.dropFirst() }
        return title
    }

    /// The whole text from the segments.
    public static func transcript(from segments: [Segment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Does the note match a search (every word, in the title, text or tags, case and accents ignored)?
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
        guard !words.isEmpty else { return true }
        let haystack = Self.fold([displayTitle, transcript, tags.joined(separator: " ")].joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// `m:ss` (or `h:mm:ss`).
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The note as Markdown: title, date and length, the marked moments, then the
    /// text in paragraphs with their times (to paste into a document or a chat).
    public func markdown() -> String {
        var out = "# \(displayTitle)\n\n"
        let when = createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute())
        out += "_\(when)" + (duration > 0 ? " · \(Self.clock(duration))" : "") + "_\n"
        if !tags.isEmpty { out += "\nTags: " + tags.joined(separator: ", ") + "\n" }
        if !marks.isEmpty {
            out += "\n## Marked\n\n"
            for m in marks.sorted(by: { $0.at < $1.at }) {
                let said = segments.last(where: { $0.start <= m.at + 0.5 })?.text ?? ""
                out += "- \(Self.clock(m.at)) \(m.label)" + (said.isEmpty ? "" : ": “\(said.trimmingCharacters(in: .whitespaces))”") + "\n"
            }
        }
        out += "\n## Notes\n\n"
        if segments.isEmpty || !transcriptMatchesSegments {
            out += transcript.isEmpty ? "_(no words yet)_\n" : transcript + "\n"
        } else {
            for p in paragraphs() { out += "**\(Self.clock(p.start))** \(p.text)\n\n" }
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }

    /// The transcript hasn't been edited by hand since the segments were made.
    public var transcriptMatchesSegments: Bool { Self.transcript(from: segments) == transcript }

    /// Segments grouped into paragraphs at pauses of 2 s or more (or every ~60 s).
    public func paragraphs(pause: Double = 2, longest: Double = 60) -> [Segment] {
        var out: [Segment] = []
        for s in segments where !s.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if var last = out.last, s.start - last.end < pause, s.end - last.start <= longest {
                last.end = s.end
                last.text += " " + s.text.trimmingCharacters(in: .whitespaces)
                out[out.count - 1] = last
            } else {
                out.append(Segment(start: s.start, end: s.end, text: s.text.trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    /// JSON as written to `note.json`: pretty, sorted keys, ISO 8601 dates.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> VoiceNote {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let note = try d.decode(VoiceNote.self, from: data)
        guard note.format == format else { throw VoiceNoteError("This isn't a Snazzy voice note.") }
        guard note.version <= 1 else { throw VoiceNoteError("This voice note needs a newer Snazzy Pro.") }
        return note
    }
}

public struct VoiceNoteError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Voice notes on disk: one folder per note (named by its id) holding `note.json`
/// and the audio. Notes are never changed behind the user's back; deleting removes
/// the folder.
public struct VoiceNoteStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func folder(for id: String) throws -> URL {
        guard Self.isSafeID(id) else { throw VoiceNoteError("That voice note's name isn't valid.") }
        return root.appending(path: id, directoryHint: .isDirectory)
    }

    /// Ids are what we make (UUIDs) or what another device made: letters, digits and dashes only.
    public static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Every readable note, newest first. Folders that aren't notes are skipped.
    public func all() -> [VoiceNote] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { name in
            guard Self.isSafeID(name),
                  let data = try? Data(contentsOf: root.appending(path: name).appending(path: VoiceNote.fileName)),
                  let note = try? VoiceNote.decode(data), note.id == name else { return nil }
            return note
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func note(_ id: String) -> VoiceNote? {
        guard let folder = try? folder(for: id),
              let data = try? Data(contentsOf: folder.appending(path: VoiceNote.fileName)) else { return nil }
        return try? VoiceNote.decode(data)
    }

    /// Saves the note (its folder is made if needed); `updated_at` is set to now unless `touch` is false.
    @discardableResult
    public func save(_ note: VoiceNote, touch: Bool = true) throws -> VoiceNote {
        var note = note
        if touch { note.updatedAt = Date() }
        let dir = try folder(for: note.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try note.encoded().write(to: dir.appending(path: VoiceNote.fileName), options: .atomic)
        return note
    }

    /// Where the note's audio is (or will be).
    public func audioURL(for note: VoiceNote) -> URL? {
        guard let name = note.audio, Self.isSafeFileName(name), let dir = try? folder(for: note.id) else { return nil }
        return dir.appending(path: name)
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".." && !name.hasPrefix(".")
    }

    /// Moves an audio file into the note's folder as `audio.<ext>` and records it on the note.
    public func adoptAudio(_ file: URL, into note: inout VoiceNote) throws {
        let dir = try folder(for: note.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = file.pathExtension.isEmpty ? "m4a" : file.pathExtension.lowercased()
        let target = dir.appending(path: "audio.\(ext)")
        if file.standardizedFileURL != target.standardizedFileURL {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
        }
        note.audio = target.lastPathComponent
    }

    public func delete(_ id: String) throws {
        let dir = try folder(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }
}
