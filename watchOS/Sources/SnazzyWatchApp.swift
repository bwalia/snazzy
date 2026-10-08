import Remote
import SwiftUI

/// Snazzy Pro for Apple Watch: start, pause and stop recording and change
/// slides on the Mac, through the iPhone app.
@main
struct SnazzyWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRemoteView()
                .environment(model)
                .tint(Color(red: 0.42, green: 0.36, blue: 1))
                .onChange(of: phase) { _, p in
                    if p == .active { model.refresh() }
                }
        }
    }
}

struct WatchRemoteView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if let status = model.status, let state = model.state {
            TabView {
                RecordingPage(status: status, state: state)
                SlidesPage(status: status)
            }
            .tabViewStyle(.verticalPage)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward").font(.title2).foregroundStyle(.secondary)
                Text(model.problem ?? "Waiting…").font(.footnote).multilineTextAlignment(.center)
                Button("Try Again") { model.refresh() }.controlSize(.small)
            }
            .padding()
        }
    }
}

private struct RecordingPage: View {
    @Environment(WatchModel.self) private var model
    let status: RemoteStatus
    let state: WatchState

    var body: some View {
        VStack(spacing: 6) {
            Text(stateText).font(.headline).foregroundStyle(stateColor)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(time(state.elapsed(at: context.date)))
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            HStack(spacing: 10) {
                switch status.recording {
                case "recording", "paused":
                    let paused = status.recording == "paused"
                    round(paused ? "play.fill" : "pause.fill", paused ? "Resume" : "Pause", .gray) {
                        model.send(paused ? .resumeRecording : .pauseRecording)
                    }
                    round("stop.fill", "Stop", .red) { model.send(.stopRecording) }
                case "countdown":
                    Text("Starting in \(status.countdown ?? 0)…").font(.headline)
                default:
                    round("record.circle", "Record", .red) { model.send(.startRecording) }
                }
            }
            .disabled(model.busy || status.recording == "finishing")
            if let message = model.lastResult ?? status.warnings.first {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2).multilineTextAlignment(.center)
            } else if let platform = status.broadcast {
                Label("Live on \(platform)", systemImage: "antenna.radiowaves.left.and.right").font(.caption2).foregroundStyle(.red)
            }
        }
        .navigationTitle(status.hostName)
    }

    private var stateText: String {
        switch status.recording {
        case "recording": "Recording"
        case "paused": "Paused"
        case "countdown": "Get ready"
        case "finishing": "Saving…"
        case "failed": "Failed"
        default: "Ready"
        }
    }

    private var stateColor: Color {
        switch status.recording {
        case "recording": .red
        case "paused": .orange
        default: .secondary
        }
    }

    private func round(_ symbol: String, _ label: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2.bold())
                .frame(width: 58, height: 58)
                .background(color.opacity(0.85), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func time(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct SlidesPage: View {
    @Environment(WatchModel.self) private var model
    let status: RemoteStatus

    var body: some View {
        VStack(spacing: 8) {
            if status.slideCount > 0 {
                let index = status.slideIndex ?? 0
                Text("Slide \(index + 1) of \(status.slideCount)").font(.caption).foregroundStyle(.secondary)
                Text(status.slideTitle ?? "").font(.headline).multilineTextAlignment(.center).lineLimit(3)
                HStack {
                    Button { model.send(.previousSlide) } label: { Image(systemName: "chevron.left").font(.title3.bold()) }
                        .disabled(index == 0 || model.busy)
                        .accessibilityLabel("Previous slide")
                    Button { model.send(.nextSlide) } label: { Image(systemName: "chevron.right").font(.title3.bold()) }
                        .disabled(index >= status.slideCount - 1 || model.busy)
                        .accessibilityLabel("Next slide")
                }
                if let next = status.nextSlideTitle {
                    Text("Next: \(next)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("No slide deck open on the Mac.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .navigationTitle("Slides")
    }
}
