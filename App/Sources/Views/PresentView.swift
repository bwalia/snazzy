import Builder
import CaptureEngine
import Remote
import SwiftUI

/// Presenting the open Builder deck: slide list, speaker notes as a
/// teleprompter, slide controls and "Record this deck".
struct PresentView: View {
    @Environment(AppModel.self) private var model
    var showSamples: () -> Void
    @AppStorage("SnazzyPro.notesFontSize") private var notesSize = 22.0
    @State private var error: String?

    var body: some View {
        let builder = model.builder
        if !builder.isDeckOpen {
            ContentUnavailableView {
                Label("No deck open", systemImage: "rectangle.on.rectangle")
            } description: {
                Text("Ask the assistant to make a presentation, or start from a sample deck. It opens in the Builder and you present it from here.")
            } actions: {
                Button("Browse Sample Decks", action: showSamples).buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                HSplitView {
                    slideList.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                    teleprompter.frame(minWidth: 300)
                }
                Divider()
                controls
            }
            .alert("Couldn't start recording", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var header: some View {
        let builder = model.builder
        let recorder = model.capture.recorder
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(builder.current?.name ?? "").font(.headline).lineLimit(1)
                Text("Slide \(builder.currentSlide + 1) of \(builder.deckSlides.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button {
                builder.openPopOut()
            } label: {
                Label(builder.stageOpen ? "Present Window Open" : "Open Present Window", systemImage: "rectangle.inset.filled.and.person.filled")
            }
            .help("A 16:9 window with just your slides. When you record slides, this window is what's captured, even if other windows cover it.")
            switch recorder.state {
            case .recording, .paused:
                Label(Self.time(recorder.elapsed), systemImage: recorder.state == .paused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(.red).monospacedDigit()
                Button("Stop") { Task { await model.capture.stopRecording() } }
            case .countdown(let n):
                Text("Starting in \(n)…").foregroundStyle(.secondary)
            case .finishing:
                ProgressView().controlSize(.small)
            default:
                Button {
                    record()
                } label: {
                    Label("Record This Deck", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .help("Records the slides (straight from the Present window), your camera inset and mic. Slide changes become chapters.")
            }
        }
        .padding(10)
    }

    private var slideList: some View {
        let builder = model.builder
        return ScrollViewReader { proxy in
            List(builder.deckSlides) { slide in
                Button {
                    builder.goToSlide(slide.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(slide.id + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Text(slide.displayTitle).lineLimit(2)
                        Spacer(minLength: 0)
                        if !slide.notes.isEmpty {
                            Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.secondary).help("Has speaker notes")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(slide.id == builder.currentSlide ? Color.accentColor.opacity(0.22) : Color.clear)
                .id(slide.id)
            }
            .onChange(of: builder.currentSlide) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
        }
    }

    private var teleprompter: some View {
        let builder = model.builder
        let prompter = model.prompter
        let i = builder.currentSlide
        let slide = builder.deckSlides.indices.contains(i) ? builder.deckSlides[i] : nil
        let next = builder.deckSlides.indices.contains(i + 1) ? builder.deckSlides[i + 1] : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Speaker notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button { notesSize = max(14, notesSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                    .help("Smaller notes")
                Button { notesSize = min(48, notesSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                    .help("Larger notes")
            }
            .buttonStyle(.borderless)
            if let slide, !slide.notes.isEmpty {
                PrompterScroller(text: slide.notes, fontSize: notesSize, state: prompter.anchored, since: prompter.anchor) {
                    prompter.move(to: $0)
                }
                prompterControls
            } else {
                Text("No notes for this slide. Ask the assistant: “Write speaker notes for every slide.”")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let next {
                Text("Next: \(next.displayTitle)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Last slide").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .onChange(of: "\(i)|\(slide?.notes ?? "")", initial: true) {
            prompter.show(slide: i, notes: slide?.notes)
        }
    }

    /// Play/pause and speed; the iPhone/iPad remote has the same controls.
    private var prompterControls: some View {
        let prompter = model.prompter
        return HStack(spacing: 8) {
            Button { prompter.move(to: 0) } label: { Image(systemName: "backward.end.fill") }
                .help("Back to the top")
            Button { prompter.setRunning(!prompter.running) } label: {
                Label(prompter.running ? "Pause" : "Scroll", systemImage: prompter.running ? "pause.fill" : "play.fill")
                    .frame(minWidth: 70)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .help("Scroll the notes at reading speed (⌥⌘P). Drag the notes to move through them.")
            Spacer()
            Button { prompter.perform(.slower) } label: { Image(systemName: "tortoise.fill") }
                .disabled(prompter.wordsPerMinute <= PrompterState.speeds.lowerBound)
                .help("Slower")
            Text("\(Int(prompter.wordsPerMinute)) wpm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { prompter.perform(.faster) } label: { Image(systemName: "hare.fill") }
                .disabled(prompter.wordsPerMinute >= PrompterState.speeds.upperBound)
                .help("Faster")
        }
    }

    private var controls: some View {
        let builder = model.builder
        return HStack {
            Button { builder.previousSlide() } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(builder.currentSlide == 0)
                .help("Previous slide (⌥⌘←)")
            Spacer()
            Text("Tip: say “next slide” to the assistant, or use the arrow keys in the Present window.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { builder.nextSlide() } label: { Label("Next", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle()) }
                .disabled(builder.currentSlide >= builder.deckSlides.count - 1)
                .help("Next slide (⌥⌘→)")
        }
        .controlSize(.large)
        .padding(10)
    }

    private func record() {
        let capture = model.capture
        capture.selectSlidesSource()
        model.builder.openPopOut()
        Task {
            do { try await capture.startRecording() } catch { self.error = error.localizedDescription }
        }
    }

    static func time(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}
