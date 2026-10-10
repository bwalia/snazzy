import Remote
import SwiftUI

/// The remote: recording controls, slides, the teleprompter and the assistant.
struct RemoteView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.horizontalSizeClass) private var size
    @State private var showPair = false
    @State private var showChat = false

    var body: some View {
        NavigationStack {
            Group {
                if let status = model.status {
                    if size == .regular {
                        // iPad: controls on the left, a big teleprompter on the right.
                        HStack(spacing: 0) {
                            ScrollView { Controls(status: status).padding(20) }
                                .frame(width: 380)
                            Divider()
                            Teleprompter(status: status).padding(24)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 18) {
                                Controls(status: status)
                                Teleprompter(status: status).frame(minHeight: 420)
                            }
                            .padding(16)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        ConnectionLine()
                        if case .failed = model.connection {
                            Button("Try Again") { model.reconnect() }.buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
            .navigationTitle(model.status?.hostName ?? "Snazzy Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(model.hosts) { host in
                            Menu(host.name) {
                                Button("Forget This Mac", role: .destructive) { model.forget(host) }
                            }
                        }
                        Button("Pair Another Mac…") { showPair = true }
                    } label: { Image(systemName: "desktopcomputer") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showChat = true } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                        .disabled(!model.isConnected)
                        .accessibilityLabel("Assistant")
                }
            }
            .sheet(isPresented: $showPair) { PairView(isSheet: true).environment(model) }
            .sheet(isPresented: $showChat) { AssistantChat().environment(model).presentationDetents([.medium, .large]) }
        }
    }
}

private struct Controls: View {
    @Environment(RemoteModel.self) private var model
    let status: RemoteStatus

    var body: some View {
        VStack(spacing: 18) {
            // Recording
            VStack(spacing: 6) {
                Text(stateText).font(.headline).foregroundStyle(stateColor)
                Text(time(status.elapsed)).font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(status.source).font(.footnote).foregroundStyle(.secondary)
                MicMeter(level: status.micLevel).frame(height: 6).padding(.horizontal, 30)
            }
            HStack(spacing: 22) {
                if status.recording == "recording" || status.recording == "paused" {
                    round(status.recording == "paused" ? "play.fill" : "pause.fill", status.recording == "paused" ? "Resume" : "Pause", .gray) {
                        model.send(status.recording == "paused" ? .resumeRecording : .pauseRecording)
                    }
                    .disabled(model.busy)
                    // Stop always works, even while another command is on its way.
                    round("stop.fill", "Stop", .red) { model.send(.stopRecording) }
                } else if status.recording == "countdown" {
                    Text("Starting in \(status.countdown ?? 0)…").font(.title2.bold())
                    round("xmark", "Cancel", .gray) { model.send(.stopRecording) }
                } else {
                    round("record.circle", "Record", .red, big: true) { model.send(.startRecording) }
                        .disabled(model.busy)
                }
            }
            .disabled(status.recording == "finishing")

            // Slides
            if status.slideCount > 0 {
                VStack(spacing: 10) {
                    Text("Slide \((status.slideIndex ?? 0) + 1) of \(status.slideCount)").font(.subheadline).foregroundStyle(.secondary)
                    Text(status.slideTitle ?? "").font(.title3.bold()).multilineTextAlignment(.center).lineLimit(3)
                    HStack(spacing: 14) {
                        slideButton("chevron.left", "Previous") { model.send(.previousSlide) }
                            .disabled((status.slideIndex ?? 0) == 0)
                        slideButton("chevron.right", "Next") { model.send(.nextSlide) }
                            .disabled((status.slideIndex ?? 0) >= status.slideCount - 1)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            } else {
                Text("No slide deck open on the Mac.").font(.footnote).foregroundStyle(.secondary)
            }

            if let viewers = status.liveRoomViewers {
                Label("Live room: \(viewers) watching", systemImage: "dot.radiowaves.left.and.right").font(.footnote)
            }
            if let platform = status.broadcast {
                Label("Live on \(platform)", systemImage: "antenna.radiowaves.left.and.right").font(.footnote).foregroundStyle(.red)
            }
            ForEach(status.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            }
            if let result = model.lastResult {
                Text(result).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var stateText: String {
        switch status.recording {
        case "recording": "Recording"
        case "paused": "Paused"
        case "countdown": "Get ready"
        case "finishing": "Saving…"
        case "failed": "Recording failed"
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

    private func round(_ symbol: String, _ label: String, _ color: Color, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: big ? 34 : 26, weight: .bold))
                    .frame(width: big ? 96 : 72, height: big ? 96 : 72)
                    .background(color.opacity(0.85), in: Circle())
                    .foregroundStyle(.white)
                Text(label).font(.footnote)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func slideButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).labelStyle(.iconOnly).font(.system(size: 30, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 70)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    private func time(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct MicMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.85 ? Color.red : Color.green).frame(width: g.size.width * max(0, min(1, level)))
            }
        }
        .accessibilityLabel("Microphone level")
    }
}

/// Speaker notes for the current slide (or the prompter's script): they
/// scroll with the Mac's camera prompter, which you play, pause and speed up
/// from here.
private struct Teleprompter: View {
    @Environment(RemoteModel.self) private var model
    let status: RemoteStatus
    @AppStorage("teleprompterSize") private var fontSize = 30.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(status.prompter?.script != nil ? "Script" : "Speaker notes").font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                Spacer()
                Button { fontSize = max(18, fontSize - 3) } label: { Image(systemName: "textformat.size.smaller") }
                    .accessibilityLabel("Smaller text")
                Button { fontSize = min(64, fontSize + 3) } label: { Image(systemName: "textformat.size.larger") }
                    .accessibilityLabel("Larger text")
            }
            if let prompter = status.prompter {
                // Above the notes so it's always in reach, and shown on slides
                // without notes too, so it can be paused before the next one.
                PrompterControls(prompter: prompter)
            }
            if let prompter = status.prompter, let text = prompter.script ?? status.notes, !text.isEmpty {
                PrompterScroller(text: text, fontSize: fontSize, state: prompter, since: model.statusAt) { p in
                    model.send(.prompter(.seek(p)))
                }
                .frame(minHeight: 200)
            } else {
                ScrollView {
                    Text(status.notes ?? (status.slideCount > 0 ? "No notes for this slide." : "Open a deck on the Mac to see your notes here."))
                        .font(.system(size: fontSize, weight: .medium))
                        .lineSpacing(fontSize * 0.25)
                        .foregroundStyle(status.notes == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let next = status.nextSlideTitle {
                Text("Next: \(next)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Play/pause, restart and speed for the teleprompter.
private struct PrompterControls: View {
    @Environment(RemoteModel.self) private var model
    let prompter: PrompterState

    var body: some View {
        HStack(spacing: 8) {
            Button { model.send(.prompter(.restart)) } label: {
                Image(systemName: "backward.end.fill").frame(width: 30, height: 44)
            }
            .accessibilityLabel("Back to the top")
            Button { model.send(.prompter(prompter.running ? .pause : .play)) } label: {
                Label(prompter.running ? "Pause" : "Scroll", systemImage: prompter.running ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(prompter.running ? .orange : .accentColor)
            Button { model.send(.prompter(.slower)) } label: {
                Image(systemName: "tortoise.fill").frame(width: 30, height: 44)
            }
            .disabled(prompter.wordsPerMinute <= PrompterState.speeds.lowerBound)
            .accessibilityLabel("Slower")
            Text("\(Int(prompter.wordsPerMinute))").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 30)
                .accessibilityLabel("\(Int(prompter.wordsPerMinute)) words a minute")
            Button { model.send(.prompter(.faster)) } label: {
                Image(systemName: "hare.fill").frame(width: 30, height: 44)
            }
            .disabled(prompter.wordsPerMinute >= PrompterState.speeds.upperBound)
            .accessibilityLabel("Faster")
        }
        .buttonStyle(.bordered)
    }
}

/// Talk to the assistant on the Mac (type, or use the keyboard's dictation mic).
private struct AssistantChat: View {
    @Environment(RemoteModel.self) private var model
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.chat.isEmpty {
                            Text("Ask the assistant on your Mac, e.g. “Go to the slide about pricing” or “Make the camera smaller”.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.chat, id: \.id) { m in
                            Text(m.text)
                                .accessibilityIdentifier(m.fromMe ? "myMessage" : "assistantReply")
                                .padding(10)
                                .background(m.fromMe ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: m.fromMe ? .trailing : .leading)
                        }
                    }
                    .padding()
                }
                HStack {
                    TextField("Message", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("chatField")
                        .onSubmit(send)
                    Button("Send", action: send).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func send() {
        model.ask(text)
        text = ""
    }
}
