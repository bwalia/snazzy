@preconcurrency import AVFoundation
import SnazzyCore
import SwiftUI

/// Voice Notes: record while you talk, see the words as you say them, mark the
/// good ideas, then search, play back, copy or turn a note into a deck.
struct VoiceNotesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notes = model.voiceNotes!
        @Bindable var bindable = notes
        NavigationSplitView {
            VStack(spacing: 0) {
                RecordPanel()
                Divider()
                List(selection: $bindable.selection) {
                    ForEach(notes.shown) { n in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.displayTitle).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(n.createdAt.formatted(date: .abbreviated, time: .shortened))
                                if n.duration > 0 { Text(VoiceNote.clock(n.duration)).monospacedDigit() }
                                if !n.marks.isEmpty { Label("\(n.marks.count)", systemImage: "star.fill").labelStyle(.titleAndIcon) }
                                if notes.polishing.contains(n.id) { ProgressView().controlSize(.mini) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(n.id)
                        .contextMenu {
                            Button("Copy as Text") { notes.copy(n.id) }
                            Button("Show in Finder") { notes.revealInFinder(n.id) }
                            Divider()
                            Button("Delete", role: .destructive) { notes.delete(n.id) }
                        }
                    }
                }
                .searchable(text: $bindable.query, placement: .sidebar, prompt: "Search notes")
                .overlay {
                    if notes.notes.isEmpty {
                        ContentUnavailableView("No voice notes yet", systemImage: "waveform",
                                               description: Text("Press Record and talk. The words appear as you speak, on this Mac."))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let id = notes.selection, let note = notes.note(id) {
                NoteDetail(note: note).id(id)
            } else if notes.isRecording {
                LiveWords()
            } else {
                ContentUnavailableView("Talk it through", systemImage: "mic.badge.plus",
                                       description: Text("Record a thought, a brainstorm or a meeting (⌥⌘R). Press ★ when you say something worth keeping."))
            }
        }
        .onAppear { notes.reload() }
    }
}

/// Record / Stop, the time, the level and the Mark button.
private struct RecordPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notes = model.voiceNotes!
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await notes.toggle() }
                } label: {
                    Label(notes.isRecording ? "Stop" : "Record", systemImage: notes.isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(notes.isRecording ? .red : .accentColor)
                .controlSize(.large)
                .disabled(notes.phase == .saving)
                .help("Record a voice note (⌥⌘R)")
                if notes.isRecording {
                    Button { notes.mark() } label: { Image(systemName: "star.fill") }
                        .controlSize(.large)
                        .help("Mark this moment as an idea (⌥⌘M)")
                }
            }
            if notes.isRecording, let started = notes.recordingStarted {
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(VoiceNote.clock(Date().timeIntervalSince(started))).monospacedDigit()
                    }
                    ProgressView(value: notes.level).tint(.red)
                    if !notes.pendingMarks.isEmpty { Label("\(notes.pendingMarks.count)", systemImage: "star.fill").foregroundStyle(.yellow) }
                }
                .font(.caption)
            } else if notes.phase == .saving {
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            }
            if let p = notes.problem {
                Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
    }
}

/// The words as they're said, while recording.
private struct LiveWords: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notes = model.voiceNotes!
        ScrollViewReader { proxy in
            ScrollView {
                Text(notes.partial.isEmpty ? "Listening…" : notes.partial)
                    .font(.title2)
                    .foregroundStyle(notes.partial.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                    .id("end")
            }
            .onChange(of: notes.partial) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Heard and turned into text on this Mac. Nothing is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }
}

/// One note: title, playback, the text (with times), marks, tags and what to do with it.
private struct NoteDetail: View {
    @Environment(AppModel.self) private var model
    let note: VoiceNote
    @State private var title = ""
    @State private var text = ""
    @State private var tags = ""
    @State private var player = NotePlayer()
    @State private var editing = false

    var body: some View {
        let notes = model.voiceNotes!
        VStack(alignment: .leading, spacing: 14) {
            TextField("Title", text: $title, prompt: Text(note.displayTitle))
                .textFieldStyle(.plain).font(.title.bold())
                .onSubmit { notes.update(note.id, title: title) }
            HStack(spacing: 10) {
                Text(note.createdAt.formatted(date: .complete, time: .shortened))
                Text("· \(note.device)")
                if notes.polishing.contains(note.id) {
                    ProgressView().controlSize(.small)
                    Text("Tidying the text from the recording…")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            if let url = notes.audioURL(note.id) {
                HStack {
                    Button { player.toggle(url) } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                    }
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        HStack {
                            ProgressView(value: note.duration > 0 ? min(player.time / note.duration, 1) : 0)
                            Text("\(VoiceNote.clock(player.time)) / \(VoiceNote.clock(note.duration))").monospacedDigit().font(.caption)
                        }
                    }
                }
            }
            if !note.marks.isEmpty {
                HStack {
                    ForEach(Array(note.marks.enumerated()), id: \.offset) { _, m in
                        Button { if let url = notes.audioURL(note.id) { player.play(url, from: max(0, m.at - 4)) } } label: {
                            Label("\(VoiceNote.clock(m.at)) \(m.label)", systemImage: "star.fill")
                        }
                        .buttonStyle(.bordered).tint(.yellow)
                    }
                }
            }
            Picker("", selection: $editing) {
                Text("Read").tag(false)
                Text("Edit Text").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            if editing || note.segments.isEmpty || !note.transcriptMatchesSegments {
                TextEditor(text: $text)
                    .font(.body)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .onChange(of: editing) { _, now in if !now { notes.update(note.id, transcript: text) } }
                    .onDisappear { if text != note.transcript { notes.update(note.id, transcript: text) } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(note.paragraphs().enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Button(VoiceNote.clock(p.start)) {
                                    if let url = notes.audioURL(note.id) { player.play(url, from: p.start) }
                                }
                                .buttonStyle(.link).monospacedDigit().font(.caption)
                                Text(p.text).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Image(systemName: "tag").foregroundStyle(.secondary)
                TextField("Tags, separated by commas", text: $tags)
                    .onSubmit { notes.update(note.id, tags: tags.split(separator: ",").map(String.init)) }
            }
            HStack {
                ForEach(VoiceNotesController.Ask.allCases, id: \.self) { a in
                    Button(a.label) { notes.ask(a, about: note.id) }
                }
                .disabled(note.transcript.isEmpty)
                Spacer()
                Button { notes.copy(note.id) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the note as Markdown")
                Button { notes.exportMarkdown(note.id) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Menu {
                    Button("Show in Finder") { notes.revealInFinder(note.id) }
                    Button("Transcribe Again") { Task { await notes.polish(note.id) } }
                        .disabled(notes.audioURL(note.id) == nil)
                    Divider()
                    Button("Delete Note", role: .destructive) { player.stop(); notes.delete(note.id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .fixedSize()
            }
        }
        .padding(24)
        .onAppear {
            title = note.title
            text = note.transcript
            tags = note.tags.joined(separator: ", ")
        }
        .onChange(of: note.transcript) { _, new in if !editing { text = new } }
        .onDisappear { player.stop() }
    }
}

/// Plays a note's audio from a given time.
@MainActor @Observable
final class NotePlayer {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var url: URL?

    var time: Double { player?.currentTime().seconds.isFinite == true ? player!.currentTime().seconds : 0 }

    func play(_ url: URL, from seconds: Double? = nil) {
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
