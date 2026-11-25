@preconcurrency import AVFoundation
import SnazzyCore
import SwiftUI

/// The Notes tab: a big Record button, the words as you say them, and your notes.
struct VoiceNotesView: View {
    @Environment(VoiceNotesModel.self) private var notes

    var body: some View {
        @Bindable var bindable = notes
        NavigationStack {
            List {
                ForEach(notes.shown) { n in
                    NavigationLink(value: n.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.displayTitle).font(.headline).lineLimit(2)
                            HStack(spacing: 8) {
                                Text(n.createdAt.formatted(date: .abbreviated, time: .shortened))
                                if n.duration > 0 { Text(VoiceNote.clock(n.duration)).monospacedDigit() }
                                if !n.marks.isEmpty { Label("\(n.marks.count)", systemImage: "star.fill") }
                                if notes.polishing.contains(n.id) { ProgressView().controlSize(.mini) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { notes.delete(notes.shown[i].id) }
                }
            }
            .overlay {
                if notes.notes.isEmpty && !notes.isRecording {
                    ContentUnavailableView("Talk it through", systemImage: "waveform",
                                           description: Text("Tap Record and talk: a thought, a brainstorm, a meeting. The words appear as you speak, on this device. Tap ★ when you say something worth keeping."))
                }
            }
            .searchable(text: $bindable.query, prompt: "Search notes")
            .navigationTitle("Voice Notes")
            .navigationDestination(for: String.self) { id in
                if let note = notes.note(id) { NoteDetailView(note: note) }
            }
            .safeAreaInset(edge: .bottom) { RecordBar() }
        }
        .onAppear { notes.reload() }
    }
}

/// Record / Stop, the live words, the time, the level and ★.
private struct RecordBar: View {
    @Environment(VoiceNotesModel.self) private var notes

    var body: some View {
        VStack(spacing: 10) {
            if notes.isRecording {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(notes.partial.isEmpty ? "Listening…" : notes.partial)
                            .font(.title3)
                            .foregroundStyle(notes.partial.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("end")
                    }
                    .frame(maxHeight: 180)
                    .onChange(of: notes.partial) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                HStack {
                    if let started = notes.started {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(VoiceNote.clock(Date().timeIntervalSince(started))).monospacedDigit()
                        }
                    }
                    ProgressView(value: notes.level).tint(.red)
                    if !notes.pendingMarks.isEmpty { Label("\(notes.pendingMarks.count)", systemImage: "star.fill").foregroundStyle(.yellow) }
                }
                .font(.caption)
            }
            if let p = notes.problem {
                Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 14) {
                Button {
                    Task { if notes.isRecording { await notes.stop() } else { await notes.start() } }
                } label: {
                    Label(notes.isRecording ? "Stop" : "Record", systemImage: notes.isRecording ? "stop.fill" : "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(notes.isRecording ? .red : .accentColor)
                .disabled(notes.phase == .saving)
                if notes.isRecording {
                    Button { notes.mark() } label: {
                        Image(systemName: "star.fill").font(.headline).frame(minWidth: 34, minHeight: 34)
                    }
                    .buttonStyle(.bordered).tint(.yellow)
                    .accessibilityLabel("Mark an idea")
                }
            }
        }
        .padding()
        .background(.bar)
    }
}

private struct NoteDetailView: View {
    @Environment(VoiceNotesModel.self) private var notes
    let note: VoiceNote
    @State private var title = ""
    @State private var text = ""
    @State private var tags = ""
    @State private var editing = false
    @State private var player = NotePlayer()

    var body: some View {
        List {
            Section {
                TextField("Title", text: $title, prompt: Text(note.displayTitle))
                    .font(.title3.bold())
                    .onSubmit { notes.update(note.id, title: title) }
                Text("\(note.createdAt.formatted(date: .complete, time: .shortened)) · \(note.device)")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = notes.audioURL(note.id) {
                    HStack {
                        Button { player.toggle(url) } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title)
                        }
                        .buttonStyle(.plain)
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            HStack {
                                ProgressView(value: note.duration > 0 ? min(player.time / note.duration, 1) : 0)
                                Text(VoiceNote.clock(player.time)).monospacedDigit().font(.caption)
                            }
                        }
                    }
                }
            }
            if !note.marks.isEmpty {
                Section("Marked") {
                    ForEach(Array(note.marks.enumerated()), id: \.offset) { _, m in
                        Button {
                            if let url = notes.audioURL(note.id) { player.play(url, from: max(0, m.at - 4)) }
                        } label: {
                            Label("\(VoiceNote.clock(m.at)) \(m.label)", systemImage: "star.fill")
                        }
                        .tint(.yellow)
                    }
                }
            }
            Section {
                if editing || note.segments.isEmpty || !note.transcriptMatchesSegments {
                    TextEditor(text: $text).frame(minHeight: 220)
                } else {
                    ForEach(Array(note.paragraphs().enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline) {
                            Button(VoiceNote.clock(p.start)) {
                                if let url = notes.audioURL(note.id) { player.play(url, from: p.start) }
                            }
                            .buttonStyle(.borderless).font(.caption.monospacedDigit())
                            Text(p.text).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Notes")
                    if notes.polishing.contains(note.id) { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button(editing ? "Done" : "Edit") {
                        if editing { notes.update(note.id, transcript: text) }
                        editing.toggle()
                    }
                    .font(.caption)
                }
            }
            Section {
                TextField("Tags, separated by commas", text: $tags)
                    .onSubmit { notes.update(note.id, tags: tags.split(separator: ",").map(String.init)) }
            } header: { Label("Tags", systemImage: "tag") }
        }
        .navigationTitle(note.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let md = notes.markdownFile(note.id) {
                        ShareLink(item: md) { Label("Share as Markdown", systemImage: "doc.text") }
                    }
                    if let audio = notes.audioURL(note.id) {
                        ShareLink(item: audio) { Label("Share the Audio", systemImage: "waveform") }
                    }
                    Button { UIPasteboard.general.string = note.markdown() } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                    Button { Task { await notes.polish(note.id) } } label: { Label("Transcribe Again", systemImage: "arrow.clockwise") }
                        .disabled(notes.audioURL(note.id) == nil)
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear {
            title = note.title
            text = note.transcript
            tags = note.tags.joined(separator: ", ")
        }
        .onChange(of: note.transcript) { _, new in if !editing { text = new } }
        .onDisappear {
            player.stop()
            if editing, text != note.transcript { notes.update(note.id, transcript: text) }
        }
    }
}

/// Plays a note's audio from a given time.
@MainActor @Observable
final class NotePlayer {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var url: URL?

    var time: Double {
        guard let t = player?.currentTime().seconds, t.isFinite else { return 0 }
        return t
    }

    func play(_ url: URL, from seconds: Double? = nil) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if self.url != url || player == nil {
            player = AVPlayer(url: url)
            self.url = url
        }
        if let seconds { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        player?.play()
        isPlaying = true
    }

    func toggle(_ url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            let atEnd = player.map { p in
                let d = p.currentItem?.duration.seconds ?? 0
                return d.isFinite && d > 0 && p.currentTime().seconds >= d - 0.2
            } ?? false
            play(url, from: atEnd ? 0 : nil)
        }
    }

    func stop() {
        player?.pause()
        isPlaying = false
    }
}
