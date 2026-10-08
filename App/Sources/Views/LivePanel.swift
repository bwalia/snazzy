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
                if live.addresses.count > 1 {
                    Picker("Join over", selection: Binding(get: { live.selectedAddress ?? "" }, set: { live.selectedAddress = $0 })) {
                        ForEach(live.addresses) { a in Text("\(a.label): \(a.ip)").tag(a.ip) }
                    }
                    .frame(maxWidth: 380)
                    .help("Pick the network your audience is on: Wi-Fi, or a VPN such as WireGuard")
                }
                HStack {
                    Text("Scan the QR code, or open the link on the same network.").font(.caption).foregroundStyle(.secondary)
                    Button("Refresh addresses") { live.refreshAddresses() }.buttonStyle(.link).font(.caption)
                }
                Button(role: .destructive) { live.stop() } label: { Label("End Live Room", systemImage: "stop.circle") }
                    .controlSize(.large)
            }
        }
    }
}

private struct BoardManager: View {
    @Environment(AppModel.self) private var model
    @State private var topic = ""
    @State private var message = ""
    @State private var idea = ""

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
            HStack {
                TextField("Message to everyone", text: $message, prompt: Text("Message to everyone, e.g. “Two minutes left to vote”"))
                    .onSubmit { live.announce(message) }
                Button("Send") { live.announce(message) }.disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                if !board.announcement.isEmpty {
                    Button("Clear") { live.announce(""); message = "" }
                }
            }
            if !board.announcement.isEmpty {
                Label("Showing: \(board.announcement)", systemImage: "megaphone").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Add an idea as the presenter", text: $idea)
                    .onSubmit { live.addIdea(idea); idea = "" }
                Button("Add Idea") { live.addIdea(idea); idea = "" }.disabled(idea.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if board.notes.isEmpty {
                Text("No ideas yet. They appear here as people post them.").foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(spacing: 6) {
                    ForEach(board.notes.sorted { ($0.hidden ? 1 : 0, -$0.votes) < ($1.hidden ? 1 : 0, -$1.votes) }) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("▲ \(note.votes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.text).strikethrough(note.hidden)
                                Text((note.fromHost ? "You (presenter)" : note.author) + (note.hidden ? " · hidden from the room" : "")).font(.caption).foregroundStyle(.secondary)
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

/// Going live on YouTube, LinkedIn, Twitch, Vimeo, Facebook or a custom RTMP server.
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
            Text("For a big public audience, stream to YouTube (free, searchable, keeps the replay) or LinkedIn for business viewers; for a private group, use the live room above instead. This is the one time video leaves your Mac, so it asks each time.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Where to stream
            VStack(alignment: .leading, spacing: 6) {
                Text("Stream to").font(.headline)
                ForEach(BroadcastPlatform.allCases) { p in
                    HStack {
                        Toggle(p.displayName, isOn: Binding(
                            get: { b.destinations.contains(p) },
                            set: { on in if on { b.destinations.insert(p) } else { b.destinations.remove(p) } }))
                            .disabled(b.isActive || !b.savedKeys.contains(p))
                        Spacer()
                        destinationStatus(p)
                    }
                }
                if b.ready.count > 1 {
                    Label("Streaming to \(b.ready.count) places at once needs about \(Int(((BroadcastController.uploadNeeded[b.quality.name] ?? 6) * Double(b.ready.count)).rounded())) Mbps of upload.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 560)

            // Set up a destination
            Form {
                Section("Set up") {
                    Picker("Destination", selection: $b.platform) {
                        ForEach(BroadcastPlatform.allCases) { Text($0.displayName).tag($0) }
                    }
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
                    TextField("Server", text: $serverDraft, prompt: Text(b.platform.defaultServer.isEmpty ? "rtmps://… (from the platform)" : b.platform.defaultServer))
                        .onChange(of: serverDraft) { _, v in b.servers[b.platform] = v }
                        .disabled(b.isActive)
                }
                Section("Options") {
                    Picker("Quality", selection: $b.quality) {
                        ForEach(BroadcastQuality.all) { q in Text("\(q.name) · needs about \(Int(BroadcastController.uploadNeeded[q.name] ?? 6)) Mbps upload").tag(q) }
                    }
                    .disabled(b.isActive)
                    Toggle("Also record to this Mac", isOn: $b.recordWhileLive).disabled(b.isActive)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
            .onAppear { serverDraft = b.servers[b.platform] ?? "" }
            .onChange(of: b.platform) { _, p in serverDraft = b.servers[p] ?? "" }

            Text("Viewers see you about 2–5 seconds late (YouTube's low-latency mode): fine for talks and classes. If your upload can't keep up, Snazzy Pro lowers the quality automatically and tells you.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)

            HStack {
                if b.isActive {
                    Button(role: .destructive) { Task { await b.stop() } } label: { Label("End Stream", systemImage: "stop.circle") }
                        .controlSize(.large)
                } else {
                    Button { Task { await b.confirmAndStart() } } label: {
                        Label(b.ready.isEmpty ? "Go Live" : "Go Live on \(b.ready.map(\.displayName).joined(separator: " + "))", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .disabled(b.ready.isEmpty)
                }
            }
            if let w = b.uploadWarning {
                Label(w, systemImage: "wifi.exclamationmark").foregroundStyle(.orange).font(.callout)
            }
            if let m = b.message {
                Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            ForEach(BroadcastPlatform.allCases) { p in
                if case .failed(let m) = b.states[p] {
                    Label("\(p.displayName): \(m)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
            }
        }
    }

    @ViewBuilder private func destinationStatus(_ p: BroadcastPlatform) -> some View {
        let b = model.broadcast!
        switch b.states[p] {
        case .live?: Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.red).font(.caption)
        case .connecting?: Text("Connecting…").foregroundStyle(.secondary).font(.caption)
        default:
            Text(b.savedKeys.contains(p) ? "Key saved" : "No key yet").foregroundStyle(.secondary).font(.caption)
        }
    }

    @ViewBuilder private var status: some View {
        let b = model.broadcast!
        if b.isActive, let started = b.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = Int(ctx.date.timeIntervalSince(started))
                VStack(alignment: .trailing, spacing: 2) {
                    Label("Live on \(b.liveDestinations.map(\.displayName).joined(separator: " + ")) · \(s / 60):\(String(format: "%02d", s % 60))", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.red).monospacedDigit()
                    if let up = b.uploadSummary { Text(up).font(.caption).foregroundStyle(.secondary) }
                }
            }
        } else if b.isActive {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…") }.foregroundStyle(.secondary)
        }
    }
}
