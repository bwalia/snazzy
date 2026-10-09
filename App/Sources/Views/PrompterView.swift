import AppKit
import SnazzyCore
import SwiftUI

/// The camera prompter's content: large text scrolling upwards, with the line
/// to read near the top (closest to the camera) and controls on hover.
struct PrompterView: View {
    @Environment(PrompterController.self) private var prompter
    @State private var hovering = false
    @State private var dragStart: Double?

    /// The reading line, as a fraction of the height from the top.
    private let readingLine = 0.18

    var body: some View {
        @Bindable var prompter = prompter
        let s = prompter.settings
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16).fill(.black.opacity(s.opacity))
            if prompter.isEditing {
                editor
            } else {
                reader
            }
            handle
            if hovering || !prompter.isScrolling || prompter.isEditing {
                VStack { Spacer(); controls }
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // The window's size is the user's; the text scrolls inside it rather
        // than making the window grow to fit.
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 110, maxHeight: .infinity)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .preferredColorScheme(.dark)
    }

    private var reader: some View {
        let s = prompter.settings
        let text = prompter.text
        return GeometryReader { geo in
            let lineY = geo.size.height * readingLine
            Text(text.isEmpty ? prompter.placeholder : text)
                .font(.system(size: s.fontSize, weight: .medium))
                .lineSpacing(s.fontSize * 0.25)
                .multilineTextAlignment(.center)
                .foregroundStyle(text.isEmpty ? .white.opacity(0.5) : .white)
                .frame(width: max(0, geo.size.width - 48))
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { t in
                    Color.clear
                        .onAppear { prompter.contentHeight = t.size.height }
                        .onChange(of: t.size.height) { _, h in prompter.contentHeight = h }
                })
                .offset(y: lineY - prompter.offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                // Fade out towards the bottom, so the eye stays near the top.
                // (and out at the very top, where read lines leave).
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.5),
                                             .init(color: .black.opacity(0.12), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { v in
                        if dragStart == nil { dragStart = prompter.offset }
                        prompter.offset = min(max(0, (dragStart ?? 0) - v.translation.height), prompter.contentHeight)
                    }
                    .onEnded { _ in dragStart = nil })
            // The reading line: a small marker on each side.
            HStack {
                Image(systemName: "arrowtriangle.right.fill")
                Spacer()
                Image(systemName: "arrowtriangle.left.fill")
            }
            .font(.system(size: 9))
            .foregroundStyle(Color.accentColor.opacity(0.9))
            .padding(.horizontal, 8)
            .position(x: geo.size.width / 2, y: lineY + s.fontSize * 0.6)
        }
    }

    private var editor: some View {
        @Bindable var prompter = prompter
        return TextEditor(text: Binding(get: { prompter.settings.script },
                                        set: { prompter.settings.script = String($0.prefix(PrompterSettings.maxScript)) }))
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .padding(EdgeInsets(top: 22, leading: 14, bottom: 48, trailing: 14))
    }

    /// Drag here to move the window (the text itself drags to scroll).
    private var handle: some View {
        Capsule().fill(.white.opacity(hovering ? 0.35 : 0.15))
            .frame(width: 44, height: 5)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, minHeight: 18)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .help("Drag to move")
    }

    private var controls: some View {
        @Bindable var prompter = prompter
        let s = prompter.settings
        return HStack(spacing: 10) {
            if prompter.isEditing {
                Text("\(Prompter.wordCount(s.script)) words").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    prompter.isEditing = false
                    prompter.settings.source = .script
                    prompter.restart()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button { prompter.toggleScrolling() } label: {
                    Image(systemName: prompter.isScrolling ? "pause.fill" : "play.fill")
                }
                .help(prompter.isScrolling ? "Pause" : "Start scrolling")
                Button { prompter.restart() } label: { Image(systemName: "backward.end.fill") }
                    .help("Back to the start")
                Divider().frame(height: 14)
                Button { prompter.settings.wordsPerMinute = max(PrompterSettings.speedRange.lowerBound, s.wordsPerMinute - 10) } label: { Image(systemName: "tortoise.fill") }
                    .help("Slower")
                Text("\(Int(s.wordsPerMinute)) wpm").font(.caption.monospacedDigit()).frame(minWidth: 52)
                Button { prompter.settings.wordsPerMinute = min(PrompterSettings.speedRange.upperBound, s.wordsPerMinute + 10) } label: { Image(systemName: "hare.fill") }
                    .help("Faster")
                Divider().frame(height: 14)
                Button { prompter.settings.fontSize = max(PrompterSettings.fontRange.lowerBound, s.fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                    .help("Smaller text")
                Button { prompter.settings.fontSize = min(PrompterSettings.fontRange.upperBound, s.fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                    .help("Larger text")
                Spacer()
                Picker("Show", selection: $prompter.settings.source) {
                    Text("Slide notes").tag(PrompterSettings.Source.notes)
                    Text("Script").tag(PrompterSettings.Source.script)
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: s.source) { _, _ in prompter.restart() }
                Button { prompter.isEditing = true } label: { Image(systemName: "pencil") }
                    .help("Type or paste a script")
                Menu {
                    Toggle("Start and pause with the recording", isOn: $prompter.settings.followsRecording)
                    Menu("Background") {
                        ForEach([0.5, 0.65, 0.8, 0.95], id: \.self) { o in
                            Button("\(Int(o * 100))%") { prompter.settings.opacity = o }
                        }
                    }
                    Button("Put Under the Camera") { prompter.placeUnderCamera() }
                    Menu("Show On") {
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { i, screen in
                            Button(screen.localizedName + (screen.safeAreaInsets.top > 0 ? " (camera)" : "")) { prompter.move(to: screen) }
                        }
                    }
                    Divider()
                    Button("Hide Prompter") { prompter.hide() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity)
        .clipped()
        .background(.black.opacity(0.55))
    }
}
