import AVFoundation
import AVKit
import AppKit
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
    private(set) var busy: String?

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private var trimWindows: [String: NSWindow] = [:]

    var folder: URL { Recorder.defaultFolder }

    init(app: AppModel) {
        self.app = app
        settings = DeveloperSettings.load()
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

    func disabled(_ name: String) -> CaptureActionError {
        CaptureActionError(message: "\(name) is turned off. Turn it on in Settings › Developer.")
    }
}
