import AppKit
import CaptureEngine
import Foundation
import Observation
import SnazzyCore
import UniformTypeIdentifiers

/// Voice notes: press record and talk (a thought, a brainstorm, a meeting). The
/// words appear as they're said, the audio is kept, and once it stops the whole
/// recording is transcribed again for cleaner text with times. Everything happens
/// on this Mac; a note goes to the assistant only when the user asks (Make a Deck,
/// Summarise), through the chat's usual cloud consent.
@MainActor @Observable
final class VoiceNotesController {
    enum Phase: Equatable {
        case idle, recording, saving
    }

    private(set) var notes: [VoiceNote] = []
    private(set) var phase: Phase = .idle
    private(set) var recordingStarted: Date?
    /// Marks made during the recording (seconds in).
    private(set) var pendingMarks: [VoiceNote.Mark] = []
    /// Notes whose text is being made again from the audio.
    private(set) var polishing: Set<String> = []
    var selection: String?
    var query = ""
    var problem: String?
    /// Opens the Voice Notes window.
    var windowRequest = 0

    var partial: String { speech.partial }
    var level: Double { speech.level }
    var isRecording: Bool { phase == .recording }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored let speech = SpeechInput()
    @ObservationIgnored let store: VoiceNoteStore

    static var folder: URL {
        #if DEBUG
        // Screenshots and checks use a folder of sample notes, never the user's own.
        if let path = UserDefaults.standard.string(forKey: "SnazzyPro.voiceNotesFolder") { return URL(fileURLWithPath: path, isDirectory: true) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Snazzy Pro/Voice Notes", isDirectory: true)
    }

    init(app: AppModel, root: URL = VoiceNotesController.folder) {
        self.app = app
        store = VoiceNoteStore(root: root)
        reload()
    }

    func reload() { notes = store.all() }

    var shown: [VoiceNote] { notes.filter { $0.matches(query) } }

    func note(_ id: String) -> VoiceNote? { notes.first { $0.id == id } }

    // MARK: Recording

    /// Starts a note on the chosen mic. Words appear in `partial` as they're said.
    func start() async {
        guard phase == .idle else { return }
        problem = nil
        pendingMarks = []
        let scratch = FileManager.default.temporaryDirectory.appending(path: "voice-note-\(UUID().uuidString)", directoryHint: .isDirectory)
        await speech.start(micID: app.capture.setup.mic?.uniqueID, saveAudioTo: scratch)
        if case .failed(let why) = speech.state {
            problem = why
            return
        }
        recordingStarted = Date()
        phase = .recording
        Log.app.info("Voice note started")
    }

    /// Marks this moment ("that's an idea"); shown in the note and its Markdown.
    func mark(_ label: String = "Idea") {
        guard isRecording, let recordingStarted else { return }
        pendingMarks.append(VoiceNote.Mark(at: Date().timeIntervalSince(recordingStarted), label: label))
    }

    /// Stops and saves the note (live text now, cleaner text from the audio shortly after).
    @discardableResult
    func stop() async -> VoiceNote? {
        guard phase == .recording else { return nil }
        phase = .saving
        defer { phase = .idle; recordingStarted = nil }
        guard let result = await speech.stop() else { return nil }
        var note = VoiceNote(duration: result.duration, transcript: result.text, marks: pendingMarks,
                             device: "Mac", language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                             transcribedBy: result.text.isEmpty ? "none" : "on-device")
        pendingMarks = []
        do {
            if let audio = result.audioURL {
                try store.adoptAudio(audio, into: &note)
                try? FileManager.default.removeItem(at: audio.deletingLastPathComponent())
            }
            guard note.audio != nil || !note.transcript.isEmpty else {
                problem = "Nothing was recorded. Check the microphone in Settings › Capture."
                return nil
            }
            note = try store.save(note)
        } catch {
            problem = "The voice note couldn't be saved: \(error.localizedDescription)"
            return nil
        }
        reload()
        selection = note.id
        Log.app.info("Voice note saved (\(Int(note.duration), privacy: .public) s)")
        let id = note.id
        Task { await polish(id) }
        return note
    }

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    /// Transcribes the note's audio again on this Mac: the whole recording, with times.
    func polish(_ id: String) async {
        guard var note = store.note(id), let audio = store.audioURL(for: note), !polishing.contains(id) else { return }
        polishing.insert(id)
        defer { polishing.remove(id) }
        do {
            let words = try await RecordingTranscriber.words(in: audio)
            guard !words.isEmpty else { return }
            let segments = Captions.cues(from: words).map { VoiceNote.Segment(start: $0.start, end: $0.end, text: $0.text) }
            // Don't overwrite text the user has edited since it was saved.
            guard let current = store.note(id), current.transcript == note.transcript else { return }
            note = current
            note.segments = segments
            note.transcript = VoiceNote.transcript(from: segments)
            note.transcribedBy = "on-device"
            if note.duration <= 0, let last = segments.last { note.duration = last.end }
            try store.save(note)
            reload()
        } catch {
            // The live text stays; this only improves it.
            Log.app.info("Voice note polish skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Editing

    func update(_ id: String, title: String? = nil, transcript: String? = nil, tags: [String]? = nil) {
        guard var note = store.note(id) else { return }
        if let title { note.title = title }
        if let transcript, transcript != note.transcript {
            note.transcript = transcript
            if note.transcribedBy == "none" { note.transcribedBy = "typed" }
        }
        if let tags { note.tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        do {
            try store.save(note)
            reload()
        } catch {
            problem = error.localizedDescription
        }
    }

    func delete(_ id: String) {
        do {
            try store.delete(id)
            if selection == id { selection = nil }
            reload()
        } catch {
            problem = error.localizedDescription
        }
    }

    func audioURL(_ id: String) -> URL? { note(id).flatMap(store.audioURL(for:)) }

    // MARK: Sharing

    func copy(_ id: String) {
        guard let note = note(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.markdown(), forType: .string)
    }

    func exportMarkdown(_ id: String) {
        guard let note = note(id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.fileName(note.displayTitle) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try note.markdown().write(to: url, atomically: true, encoding: .utf8) } catch { problem = error.localizedDescription }
    }

    func revealInFinder(_ id: String) {
        guard let folder = try? store.folder(for: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    static func fileName(_ title: String) -> String {
        let cleaned = title.map { "/:\\".contains($0) ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces).prefix(80).description
    }

    /// Hands the note to the assistant (the chat asks before anything goes to a cloud model).
    enum Ask: String, CaseIterable {
        case deck, summary, actions

        var label: String {
            switch self {
            case .deck: "Make a Deck"
            case .summary: "Summarise"
            case .actions: "List Action Points"
            }
        }

        func prompt(_ note: VoiceNote) -> String {
            let request = switch self {
            case .deck: "Make a short slide deck from the ideas in this voice note of mine. Keep my ideas and wording where you can, group them into a few clear slides, and put what I said in the speaker notes."
            case .summary: "Summarise this voice note of mine: a one-line gist, then the main points as bullets. Keep the ideas I marked."
            case .actions: "List the action points and decisions in this voice note of mine, as a checklist with who/when where I said it."
            }
            return request + "\n\n<voice_note>\n" + note.markdown() + "</voice_note>"
        }
    }

    func ask(_ ask: Ask, about id: String) {
        guard let note = note(id) else { return }
        if app.chat.send(ask.prompt(note)) {
            NSApp.windows.first { $0.title == "Snazzy Pro" }?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Assistant tools

    func listJSON() -> JSONValue {
        ["folder": "~/Movies/Snazzy Pro/Voice Notes", "recording": .bool(isRecording),
         "notes": .array(notes.prefix(100).map { n in
             ["id": .string(n.id), "title": .string(n.displayTitle), "created": .string(n.createdAt.formatted(.iso8601)),
              "seconds": .number(n.duration.rounded()), "marks": .number(Double(n.marks.count)),
              "tags": .array(n.tags.map(JSONValue.string))]
         })]
    }

    /// A note's text for the assistant. Off this Mac only after the user reviews it.
    func readJSON(_ id: String, offMac: String?) throws -> JSONValue {
        let wanted = id == "latest" ? notes.first?.id : id
        guard let wanted, let note = note(wanted) else {
            throw CaptureActionError(message: "No voice note “\(id)”. Use list_voice_notes to see them.")
        }
        let text = note.markdown()
        if let offMac, !CloudReview.confirm(provider: offMac, what: "this voice note", text: text,
                                            note: "Send it only if you want the assistant to work with it.") {
            return ["id": .string(note.id), "title": .string(note.displayTitle), "status": "The user chose not to send this note."]
        }
        return ["id": .string(note.id), "title": .string(note.displayTitle), "markdown": .string(text)]
    }

    func stateJSON() -> JSONValue {
        ["recording": .bool(isRecording), "seconds": .number(recordingStarted.map { Date().timeIntervalSince($0).rounded() } ?? 0),
         "marks": .number(Double(pendingMarks.count))]
    }
}
