import AppKit
import CaptureEngine
import SwiftUI

/// Record / pause / stop with elapsed time and mic level, in the toolbar.
struct RecordingControls: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        let capture = model.capture
        let recorder = capture.recorder
        HStack(spacing: 8) {
            switch recorder.state {
            case .countdown(let n):
                Text("Recording in \(n)…").monospacedDigit().foregroundStyle(.red)
                Button("Cancel") { recorder.cancelCountdown() }
            case .recording, .paused:
                Circle().fill(recorder.state == .paused ? Color.orange : Color.red).frame(width: 9, height: 9)
                    .opacity(recorder.state == .recording ? 1 : 0.6)
                Text(Self.format(recorder.elapsed)).monospacedDigit()
                LevelMeter(level: recorder.micLevel)
                if let warning = recorder.warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(warning)
                }
                if let feed = capture.insetFeed, feed.state != .live {
                    Image(systemName: "video.slash").foregroundStyle(.orange).help("Camera: \(feed.state.description). The screen and mic keep recording.")
                }
                Button {
                    if recorder.state == .paused { capture.resumeRecording() } else { capture.pauseRecording() }
                } label: {
                    Image(systemName: recorder.state == .paused ? "record.circle" : "pause.fill")
                }
                .help(recorder.state == .paused ? "Resume (⌃⌘P)" : "Pause (⌃⌘P)")
                Button {
                    Task { await capture.stopRecording() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop and save (⇧⌘R)")
            case .finishing:
                ProgressView().controlSize(.small)
                Text("Saving…")
            case .idle, .failed:
                Button {
                    Task {
                        do { error = nil; try await capture.startRecording() } catch let e { error = e.localizedDescription }
                    }
                } label: {
                    Label("Record", systemImage: "record.circle").foregroundStyle(.red)
                }
                .help(error ?? "Record the selected screen with camera inset and mic (⇧⌘R)")
                if case .failed(let message) = recorder.state {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                } else if error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error ?? "")
                }
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shown after a recording is saved.
struct RecordingSavedBanner: View {
    @Environment(AppModel.self) private var model
    @State private var dismissed: URL?

    var body: some View {
        if let result = model.capture.recorder.lastResult, result.composite != dismissed, !model.capture.recorder.isActive {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved \(result.composite.lastPathComponent)").font(.callout.weight(.medium))
                    Text("\(RecordingControls.format(result.duration))\(result.freezes.isEmpty ? "" : " · camera froze \(result.freezes.count)×")\(result.droppedFrames > 0 ? " · \(result.droppedFrames) dropped frames" : "") · raw tracks kept")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Open") { NSWorkspace.shared.open(result.composite) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.composite]) }
                Button { dismissed = result.composite } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }
}
