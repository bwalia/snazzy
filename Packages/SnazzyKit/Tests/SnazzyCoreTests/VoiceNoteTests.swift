import Foundation
import Testing
@testable import SnazzyCore

@Suite struct VoiceNoteTests {
    static let fixed = Date(timeIntervalSince1970: 1_767_323_045)  // 2026-01-02T03:04:05Z

    static var sample: VoiceNote {
        let segments = [
            VoiceNote.Segment(start: 0, end: 2.5, text: "Okay, ideas for the spring launch."),
            VoiceNote.Segment(start: 2.6, end: 6, text: "We could run a live demo every Friday."),
            VoiceNote.Segment(start: 9.5, end: 13.25, text: "And send the slides to everyone who joins."),
        ]
        return VoiceNote(id: "0f8fad5b-d9cb-469f-a165-70867728950e", createdAt: fixed, duration: 14,
                         audio: "audio.m4a", transcript: VoiceNote.transcript(from: segments), segments: segments,
                         marks: [VoiceNote.Mark(at: 4.2)], tags: ["launch"], device: "Mac", language: "en-GB")
    }

    /// docs/specs/fixtures/voice-note.json: what the Mac writes, read by the Rust tests.
    @Test func fixture() throws {
        let data = try Self.sample.encoded()
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/specs/fixtures/voice-note.json")
        if ProcessInfo.processInfo.environment["SNAZZY_WRITE_FIXTURES"] == "1" {
            try data.write(to: url)
        } else {
            #expect(try Data(contentsOf: url) == data, "docs/specs/fixtures/voice-note.json is out of date: run SNAZZY_WRITE_FIXTURES=1 swift test")
        }
        #expect(try VoiceNote.decode(data) == Self.sample)
    }

    @Test func titleFromFirstWords() {
        #expect(VoiceNote.title(from: "okay, ideas for the spring launch. More later") == "Okay, ideas for the spring launch")
        #expect(VoiceNote.title(from: "one two three four five six seven eight nine") == "One two three four five six seven")
        #expect(VoiceNote.title(from: "  ") == "")
        #expect(Self.sample.displayTitle == "Okay, ideas for the spring launch")
        var typed = Self.sample
        typed.title = "Launch ideas"
        #expect(typed.displayTitle == "Launch ideas")
    }

    @Test func search() {
        let n = Self.sample
        #expect(n.matches("friday DEMO"))
        #expect(n.matches("launch"))
        #expect(!n.matches("friday budget"))
        #expect(n.matches(""))
        var accented = n
        accented.transcript = "Un café à Montréal"
        #expect(accented.matches("cafe montreal"))
    }

    @Test func tolerantDecoding() throws {
        let note = try VoiceNote.decode(Data(#"{"format":"snazzy-voice-note","id":"abc-1"}"#.utf8))
        #expect(note.transcript.isEmpty && note.segments.isEmpty && note.marks.isEmpty && note.transcribedBy == "none")
        #expect(throws: VoiceNoteError.self) { try VoiceNote.decode(Data(#"{"format":"other","id":"abc"}"#.utf8)) }
        #expect(throws: VoiceNoteError.self) { try VoiceNote.decode(Data(#"{"format":"snazzy-voice-note","version":2,"id":"abc"}"#.utf8)) }
    }

    @Test func markdownHasMarksAndParagraphs() {
        let md = Self.sample.markdown()
        #expect(md.hasPrefix("# Okay, ideas for the spring launch\n"))
        #expect(md.contains("- 0:04 Idea: “We could run a live demo every Friday.”"))
        // A pause of 3.5 s starts a new paragraph.
        #expect(md.contains("**0:00** Okay, ideas for the spring launch. We could run a live demo every Friday.\n"))
        #expect(md.contains("**0:09** And send the slides to everyone who joins."))
        var edited = Self.sample
        edited.transcript = "Rewritten by hand."
        #expect(edited.markdown().contains("## Notes\n\nRewritten by hand.\n"))
    }

    @Test func clock() {
        #expect(VoiceNote.clock(0) == "0:00")
        #expect(VoiceNote.clock(75.9) == "1:15")
        #expect(VoiceNote.clock(3725) == "1:02:05")
    }

    @Test func store() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "voice-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceNoteStore(root: root)
        var a = Self.sample
        let audio = FileManager.default.temporaryDirectory.appending(path: "rec-\(UUID().uuidString).m4a")
        try Data("not really audio".utf8).write(to: audio)
        try store.adoptAudio(audio, into: &a)
        #expect(a.audio == "audio.m4a" && !FileManager.default.fileExists(atPath: audio.path))
        try store.save(a)
        var b = VoiceNote(id: "second", createdAt: Self.fixed.addingTimeInterval(60), device: "iPhone")
        b.transcript = "Later note"
        try store.save(b)
        try FileManager.default.createDirectory(at: root.appending(path: "not-a-note"), withIntermediateDirectories: true)
        #expect(store.all().map(\.id) == ["second", a.id])
        #expect(store.audioURL(for: a).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        try store.delete(a.id)
        #expect(store.all().map(\.id) == ["second"])
        #expect(throws: VoiceNoteError.self) { try store.folder(for: "../escape") }
        var evil = b
        evil.audio = "../../etc/passwd"
        #expect(store.audioURL(for: evil) == nil)
    }
}
