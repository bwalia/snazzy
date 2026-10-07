import AVFoundation
import AVKit
import AppKit
import Assistant
import CaptureEngine
import Foundation
import Observation
import SnazzyCore

/// A recording on disk (`~/Movies/Snazzy Pro/Recordings`), with what's been
/// made from it.
struct RecordingItem: Identifiable, Hashable {
    /// The file name without extension, e.g. "presentation-20261007-214527".
    var id: String
    var url: URL
    var date: Date
    var size: Int64
    var rawFolder: URL?

    func sidecar(_ ext: String) -> URL { url.deletingPathExtension().appendingPathExtension(ext) }
    var hasCaptions: Bool { FileManager.default.fileExists(atPath: sidecar("srt").path) }
    var hasSummary: Bool { FileManager.default.fileExists(atPath: sidecar("md").path) }
}

/// The developer features (Settings › Developer): trim, captions and
/// summaries, share links, pull-request demos, reading the front window.
/// Buttons and assistant tools both call these methods.
@MainActor @Observable
final class DeveloperController {
    var settings: DeveloperSettings {
        didSet { if settings != oldValue { settings.save() } }
    }
    private(set) var recordings: [RecordingItem] = []
    /// Shown in the Recordings tab while something runs.
    var busy: String?

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private(set) var share: ShareService!
    /// The last share result, shown as a sheet with ready-to-paste text.
    var lastShare: ShareService.Outcome?
    @ObservationIgnored private var trimWindows: [String: NSWindow] = [:]

    var folder: URL { Recorder.defaultFolder }

    init(app: AppModel) {
        self.app = app
        settings = DeveloperSettings.load()
        share = ShareService(app: app)
        refresh()
    }

    // MARK: Library

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        recordings = files.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }.map { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            return RecordingItem(id: url.deletingPathExtension().lastPathComponent, url: url,
                                 date: values?.creationDate ?? .distantPast, size: Int64(values?.fileSize ?? 0),
                                 rawFolder: RecordingEditor.rawFolder(for: url))
        }
        .sorted { $0.date > $1.date }
    }

    /// Finds a recording by id, "latest"/"last", or part of its name.
    func recording(_ query: String?) throws -> RecordingItem {
        refresh()
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty || ["latest", "last", "newest", "most recent"].contains(q.lowercased()) {
            guard let first = recordings.first else { throw CaptureActionError(message: "There are no recordings yet.") }
            return first
        }
        if let exact = recordings.first(where: { $0.id == q || $0.url.lastPathComponent == q }) { return exact }
        if let partial = recordings.first(where: { $0.id.localizedCaseInsensitiveContains(q) }) { return partial }
        throw CaptureActionError(message: "No recording called “\(q)”. Use list_recordings to see them.")
    }

    func recordingsJSON() async -> JSONValue {
        refresh()
        var out: [JSONValue] = []
        for item in recordings.prefix(30) {
            let duration = (try? await AVURLAsset(url: item.url).load(.duration).seconds) ?? 0
            out.append([
                "recording_id": .string(item.id),
                "file": .string(item.url.lastPathComponent),
                "recorded": .string(item.date.formatted(date: .abbreviated, time: .shortened)),
                "duration_seconds": .number((duration * 10).rounded() / 10),
                "has_captions": .bool(item.hasCaptions),
                "has_summary": .bool(item.hasSummary),
                "raw_tracks": .bool(item.rawFolder != nil),
            ])
        }
        return ["recordings": .array(out), "folder": "~/Movies/Snazzy Pro/Recordings"]
    }

    func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Feature 1: trim

    func trim(_ item: RecordingItem, start: Double, end: Double) async throws -> RecordingEditor.TrimResult {
        guard settings.trimEnabled else { throw disabled("Trim") }
        busy = "Trimming \(item.id)…"
        defer { busy = nil }
        let result = try await RecordingEditor.trim(item.url, start: start, end: end)
        refresh()
        app.capture.diagnostics.log("Trimmed \(item.id) → \(result.video.lastPathComponent)", category: "recording")
        app.chat.logSession("recording_trimmed", ["from": .string(item.id), "file": .string(result.video.lastPathComponent)])
        return result
    }

    /// Opens Apple's trim view (QuickTime-style handles) for a recording.
    func openTrimmer(_ item: RecordingItem) {
        if let window = trimWindows[item.id] { window.makeKeyAndOrderFront(nil); return }
        let player = AVPlayer(url: item.url)
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Trim \(item.id)"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        trimWindows[item.id] = window
        let id = item.id
        // Wait until the item is ready, then show the trim handles.
        Task { @MainActor [weak self] in
            for _ in 0..<50 where !view.canBeginTrimming { try? await Task.sleep(for: .milliseconds(100)) }
            let result = await view.beginTrimming()
            window.close()
            self?.trimWindows[id] = nil
            guard let self, result == .okButton, let current = player.currentItem else { return }
            let start = current.reversePlaybackEndTime.isValid ? current.reversePlaybackEndTime.seconds : 0
            let end = current.forwardPlaybackEndTime.isValid ? current.forwardPlaybackEndTime.seconds : current.duration.seconds
            do {
                let r = try await self.trim(item, start: start, end: end)
                NSWorkspace.shared.activateFileViewerSelecting([r.video])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Feature 2: captions and summary

    struct CaptionResult {
        var srt: URL
        var vtt: URL
        var burned: URL?
        var cues: [CaptionCue]
    }

    /// Transcribes on this Mac and writes `<name>.srt` / `<name>.vtt`
    /// (plus a captioned copy if asked).
    func makeCaptions(_ item: RecordingItem, burnIn: Bool) async throws -> CaptionResult {
        guard settings.captionsEnabled else { throw disabled("Captions") }
        busy = "Transcribing \(item.id) on this Mac…"
        defer { busy = nil }
        let words = try await RecordingTranscriber.words(in: item.url)
        guard !words.isEmpty else { throw CaptureActionError(message: "No speech found in \(item.id).") }
        let cues = Captions.cues(from: words)
        let srt = item.sidecar("srt"), vtt = item.sidecar("vtt")
        try Captions.srt(cues).write(to: srt, atomically: true, encoding: .utf8)
        try Captions.vtt(cues).write(to: vtt, atomically: true, encoding: .utf8)
        var burned: URL?
        if burnIn {
            busy = "Adding captions to a copy of \(item.id)…"
            let out = RecordingEditor.sibling(of: item.url, suffix: "captioned", ext: "mp4")
            try await CaptionBurner.burn(item.url, cues: cues, to: out)
            burned = out
        }
        refresh()
        app.chat.logSession("captions_made", ["recording": .string(item.id), "cues": .number(Double(cues.count))])
        return CaptionResult(srt: srt, vtt: vtt, burned: burned, cues: cues)
    }

    /// Captions from the .srt if they exist, otherwise made now.
    func captionCues(_ item: RecordingItem) async throws -> [CaptionCue] {
        if let text = try? String(contentsOf: item.sidecar("srt"), encoding: .utf8) {
            let cues = Self.parseSRT(text)
            if !cues.isEmpty { return cues }
        }
        return try await makeCaptions(item, burnIn: false).cues
    }

    static func parseSRT(_ text: String) -> [CaptionCue] {
        text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 3, let arrow = lines[1].range(of: " --> ") else { return nil }
            func secs(_ s: String) -> Double? {
                let p = s.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
                return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : nil
            }
            guard let a = secs(String(lines[1][..<arrow.lowerBound])), let b = secs(String(lines[1][arrow.upperBound...])) else { return nil }
            return CaptionCue(start: a, end: b, text: lines[2...].joined(separator: "\n"))
        }
    }

    /// A title, 3–5 bullets and chapter times, written by the Writing model.
    /// Only the transcript text is sent, and only after review if the model is in the cloud.
    func summarize(_ item: RecordingItem) async throws -> URL {
        guard settings.captionsEnabled else { throw disabled("Captions and summaries") }
        let cues = try await captionCues(item)
        let selection = app.settings.selection(for: .writing)
        if let reason = app.unavailableReason(selection.provider) { throw CaptureActionError(message: reason) }
        let provider = try app.makeProvider(selection.provider)
        // The on-device model has a small context: send less of a long transcript.
        let limit = selection.provider == .appleOnDevice ? 7_000 : 120_000
        var transcript = Captions.timedTranscript(cues)
        if transcript.count > limit { transcript = String(transcript.prefix(limit)) + " …" }
        let duration = cues.last?.end ?? 0
        let chapters = duration >= 120
            ? "\n## Chapters\nOne line per topic change, \"- mm:ss Topic\", using the [mm:ss] markers in the transcript (3 to 8 lines)."
            : ""
        let prompt = """
            Summarise this recording transcript. Reply in Markdown with exactly:
            # <a short title>
            3 to 5 bullet points (lines starting with "- ") giving the key points, without timestamps.\(chapters)
            Refer to the speaker as "the speaker" or "they". Don't add anything that isn't in the transcript.

            Transcript:
            \(transcript)
            """
        if !selection.provider.isLocal {
            guard CloudReview.confirm(provider: selection.provider.displayName, what: "this transcript", text: prompt,
                                      note: "Summaries use your Writing model (\(selection.model)). Choose a local model in Settings › Models to keep it on this Mac.")
            else { throw CaptureActionError(message: "Not sent. The summary was cancelled.") }
        }
        busy = "Summarising \(item.id) with \(selection.model)…"
        defer { busy = nil }
        var text = ""
        let request = ModelRequest(model: selection.model, system: "You write concise, accurate summaries.", messages: [.user(prompt)],
                                   maxTokens: 2_000, effort: selection.provider == .anthropic ? "low" : nil)
        for try await event in provider.stream(request) {
            if case .completed(let message, _, _, _) = event { text = message.text }
        }
        guard !text.isEmpty else { throw CaptureActionError(message: "The model returned no summary.") }
        let out = item.sidecar("md")
        try text.write(to: out, atomically: true, encoding: .utf8)
        refresh()
        app.chat.logSession("summary_made", ["recording": .string(item.id), "model": .string(selection.model)])
        return out
    }

    func setBusy(_ text: String?) { busy = text }

    func disabled(_ name: String) -> CaptureActionError {
        CaptureActionError(message: "\(name) is turned off. Turn it on in Settings › Developer.")
    }
}
