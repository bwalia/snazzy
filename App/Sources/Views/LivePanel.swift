import Broadcast
import Live
import SwiftUI

/// The Live tab: start a room on the local network, show the QR code, and
/// moderate the brainstorm board.
struct LivePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.live!
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if live.isRunning { RunningRoom() } else { StartRoom() }
                if let error = live.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
                if live.isRunning { BoardManager() }
                BroadcastSection()
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StartRoom: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var live = model.live!
        VStack(alignment: .leading, spacing: 14) {
            Text("Live classroom").font(.title2.weight(.semibold))
            Text("Students on the same Wi-Fi scan a QR code and join in their browser. No app, account or internet needed: it goes straight from this Mac to them.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label("They watch what you'd record: your slides or screen, with your camera inset", systemImage: "play.rectangle")
                Label("They hear your microphone", systemImage: "mic")
                Label("They add ideas to a brainstorm board and vote; you moderate", systemImage: "lightbulb")
                Label("Afterwards, the assistant turns the ideas into a deck", systemImage: "rectangle.stack")
            }
            .font(.callout)
            Form {
                TextField("Brainstorm topic", text: $live.pendingTopic, prompt: Text("e.g. Ideas for the school fair"))
                Picker("Video quality", selection: $live.quality) {
                    ForEach(LiveController.Quality.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 520)
            Button {
                Task { await live.confirmAndStart() }
            } label: {
                Label("Start Live Room", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(live.isStarting)
            Text("Works best for up to 30–50 people on one Wi-Fi network. Students elsewhere can't join this room.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RunningRoom: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.live!
        HStack(alignment: .top, spacing: 24) {
            if let qr = live.qrCode {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .help("Students scan this with their phone camera")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(live.isStreaming ? .red : .orange).frame(width: 10, height: 10)
                    Text(live.isStreaming ? "Live" : "Board only").font(.headline)
                    Text("· \(live.viewers) watching").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Room code").font(.caption).foregroundStyle(.secondary)
                Text(live.code).font(.system(size: 40, weight: .bold, design: .monospaced)).textSelection(.enabled)
                if let url = live.joinURL {
                    HStack {
                        Text(url.absoluteString).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy the link")
                    }
                }
                Text("Scan the QR code, or open the link on the same Wi-Fi.").font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { live.stop() } label: { Label("End Live Room", systemImage: "stop.circle") }
                    .controlSize(.large)
            }
        }
    }
}

private struct BoardManager: View {
    @Environment(AppModel.self) private var model
    @State private var topic = ""

    var body: some View {
        let live = model.live!
        let board = live.board
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Text("Brainstorm board").font(.headline)
                Spacer()
                Toggle("Accepting ideas", isOn: Binding(get: { board.isOpen }, set: { live.setBoardOpen($0) }))
                    .toggleStyle(.switch)
            }
            HStack {
                TextField("Topic", text: $topic, prompt: Text("What should people brainstorm?"))
                    .onSubmit { live.setTopic(topic) }
                Button("Set Topic") { live.setTopic(topic) }.disabled(topic == board.topic)
            }
            .onAppear { topic = board.topic }
            if board.notes.isEmpty {
                Text("No ideas yet. They appear here as people post them.").foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(spacing: 6) {
                    ForEach(board.notes.sorted { ($0.hidden ? 1 : 0, -$0.votes) < ($1.hidden ? 1 : 0, -$1.votes) }) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("▲ \(note.votes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.text).strikethrough(note.hidden)
                                Text(note.author + (note.hidden ? " · hidden from the room" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(note.hidden ? "Show" : "Hide") { live.setHidden(note.id, !note.hidden) }
                            Button(role: .destructive) { live.delete(note.id) } label: { Image(systemName: "trash") }
                                .help("Delete")
                        }
                        .buttonStyle(.borderless)
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .opacity(note.hidden ? 0.6 : 1)
                    }
                }
            }
            HStack {
                Button {
                    live.turnIdeasIntoDeck()
                } label: { Label("Turn Ideas into a Deck", systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent)
                .disabled(board.ranked.isEmpty)
                Spacer()
                Button("Clear Board", role: .destructive) { live.clearBoard() }.disabled(board.notes.isEmpty)
            }
        }
    }
}

/// Going live on YouTube, Twitch, Vimeo, Facebook or a custom RTMP server.
struct BroadcastSection: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var serverDraft = ""

    var body: some View {
        @Bindable var b = model.broadcast!
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Text("Go live online").font(.title3.weight(.semibold))
                Spacer()
                status
            }
            Text("Stream the same picture and sound to YouTube, Twitch, Vimeo, Facebook or your own RTMP server. This one goes over the internet, so it asks each time.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Platform", selection: $b.platform) {
                    ForEach(BroadcastPlatform.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(b.isActive)
                LabeledContent("Stream key") {
                    if b.savedKeys.contains(b.platform) {
                        HStack {
                            Label("Saved in Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                            Button("Remove") { b.deleteKey(for: b.platform) }.disabled(b.isActive)
                        }
                    } else {
                        HStack {
                            SecureField("Stream key", text: $keyDraft, prompt: Text("Paste your stream key"))
                                .labelsHidden()
                                .frame(minWidth: 240)
                            Button("Save") { b.saveKey(keyDraft, for: b.platform); keyDraft = "" }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Text(b.platform.keyHelp).font(.caption).foregroundStyle(.secondary)
                TextField("Server", text: $serverDraft, prompt: Text(b.platform.defaultServer.isEmpty ? "rtmps://your-server/app" : b.platform.defaultServer))
                    .onSubmit { b.servers[b.platform] = serverDraft }
                    .onChange(of: serverDraft) { _, v in b.servers[b.platform] = v }
                    .disabled(b.isActive)
                Picker("Quality", selection: $b.quality) {
                    ForEach(BroadcastQuality.all) { q in Text("\(q.name) · \(String(format: "%.1f", Double(q.videoBitrate) / 1_000_000)) Mbps").tag(q) }
                }
                .disabled(b.isActive)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
            .onAppear { serverDraft = b.servers[b.platform] ?? "" }
            .onChange(of: b.platform) { _, p in serverDraft = b.servers[p] ?? "" }
            HStack {
                if b.isActive {
                    Button(role: .destructive) { Task { await b.stop() } } label: { Label("End Stream", systemImage: "stop.circle") }
                        .controlSize(.large)
                } else {
                    Button { Task { await b.confirmAndStart() } } label: { Label("Go Live on \(b.platform.displayName)", systemImage: "antenna.radiowaves.left.and.right") }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        .disabled(!b.savedKeys.contains(b.platform))
                }
            }
            if case .failed(let message) = b.state {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
        }
    }

    @ViewBuilder private var status: some View {
        let b = model.broadcast!
        switch b.state {
        case .connecting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…") }.foregroundStyle(.secondary)
        case .live:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = Int(ctx.date.timeIntervalSince(b.startedAt ?? ctx.date))
                Label("Live on \(b.platform.displayName) · \(s / 60):\(String(format: "%02d", s % 60))", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.red).monospacedDigit()
            }
        default:
            EmptyView()
        }
    }
}
