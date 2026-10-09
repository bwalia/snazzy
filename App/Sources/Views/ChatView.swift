import AppKit
import Assistant
import SnazzyCore
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var inputFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        let chat = model.chat!
        VStack(spacing: 0) {
            ChatHeader()
            Divider()
            if let preset = chat.suggestedPreset {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("This conversation used the preset “\(preset)”.").font(.callout)
                    Spacer()
                    Button("Load It") { _ = try? model.presets.load(preset) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
            }
            transcript(chat)
                .font(.system(size: model.settings.chatTextSize))
                .environment(\.chatTextSize, model.settings.chatTextSize)
            Divider()
            if model.voice.isOn { VoiceModeBar() }
            Composer(inputFocused: $inputFocused)
        }
        .background(.background)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
                    .overlay(Text("Drop to attach").font(.headline).padding(8).background(.regularMaterial, in: Capsule()))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in Composer.attach(url, to: chat) }
                }
            }
            return true
        }
        .onAppear { inputFocused = true }
    }

    private func transcript(_ chat: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.transcript.isEmpty {
                        EmptyChatHint()
                    }
                    let lastUser = chat.transcript.last(where: { $0.kind == .user })?.id
                    ForEach(chat.transcript) { item in
                        TranscriptRow(item: item, isLastUser: item.id == lastUser).id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: chat.transcript) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        let chat = model.chat!
        @Bindable var bindable = chat
        VStack(alignment: .leading, spacing: 6) {
            if chat.editingMessageID != nil {
                HStack {
                    Label("Editing: sending replaces that message and everything after it", systemImage: "pencil")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Cancel") { chat.cancelEditing() }.buttonStyle(.borderless).font(.caption)
                }
            }
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(chat.attachments) { a in
                            HStack(spacing: 4) {
                                Image(systemName: { if case .image = a.content { "photo" } else { "doc.text" } }())
                                Text(a.name).lineLimit(1)
                                Button { chat.attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.quaternary))
                        }
                    }
                }
            }
            if chat.speech.state == .listening || chat.speech.state == .finishing {
                HStack(spacing: 8) {
                    LevelMeter(level: chat.speech.level)
                    Text(chat.speech.partial.isEmpty ? "Listening…" : chat.speech.partial)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    if chat.speech.onDevice { Text("on-device").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { pickFiles(chat) } label: { Image(systemName: "paperclip").font(.title3) }
                    .buttonStyle(.borderless)
                    .help("Attach images or text files (or drop them here)")
                TextField("Ask Snazzy… (⏎ send, ⇧⏎ new line)", text: $bindable.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: model.settings.chatTextSize))
                    .lineLimit(1...10)
                    .focused(inputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        chat.sendDraft()
                        return .handled
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                Button { chat.toggleVoice() } label: {
                    Image(systemName: chat.speech.isListening ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(chat.speech.isListening ? .red : .secondary)
                        .symbolEffect(.pulse, isActive: chat.speech.isListening)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help(chat.speech.isListening ? "Stop and transcribe (⇧⌘L)" : "Talk to the assistant (⇧⌘L)")
                Button { model.voice.toggle() } label: {
                    Image(systemName: model.voice.isOn ? "waveform.circle.fill" : "waveform.circle")
                        .font(.title2)
                        .foregroundStyle(model.voice.isOn ? Color.accentColor : .secondary)
                        .symbolEffect(.variableColor.iterative, isActive: model.voice.state == .speaking)
                }
                .buttonStyle(.borderless)
                .help(model.voice.isOn ? "Voice Mode is on: click to turn it off (⌥⌘V)" : "Voice Mode: talk hands-free; it speaks back and can run your slides and recording (⌥⌘V)")
                if chat.isRunning {
                    Button(action: chat.stop) { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .help("Stop generating (⌘.)")
                } else {
                    Button { chat.sendDraft() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.attachments.isEmpty)
                        .help("Send")
                }
            }
        }
        .padding(10)
    }

    private func pickFiles(_ chat: ChatSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Attach images or text files"
        if panel.runModal() == .OK {
            for url in panel.urls { Self.attach(url, to: chat) }
        }
    }

    @MainActor static func attach(_ url: URL, to chat: ChatSession) {
        do {
            chat.attachments.append(try Attachment.load(url))
        } catch {
            NSSound.beep()
            Log.app.notice("Attachment rejected: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct LevelMeter: View {
    let level: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(i) / 8 < level ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: 6 + CGFloat(i) * 1.5)
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }
}

struct EmptyChatHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What are we making?").font(.title3.weight(.semibold))
            Group {
                Text("• “Make a 6-slide deck on our Q3 DevOps results for the leadership team.”")
                Text("• “Build a clickable prototype of an incident dashboard.”")
                Text("• “Use my USB mic and put my iPad camera bottom-right.”")
                Text("Click the mic (⇧⌘L) to talk instead of typing.")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}

struct TranscriptRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    var isLastUser = false
    @Environment(\.chatTextSize) private var textSize
    @State private var showDetail = false
    @State private var hovering = false

    var body: some View {
        Group {
            switch item.kind {
            case .user: user
            case .assistant: assistant
            case .tool(let name): tool(name)
            case .notice(let isError):
                Label(item.text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.system(size: textSize - 1))
                    .foregroundStyle(isError ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        .onHover { hovering = $0 }
    }

    private var user: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 40)
            if hovering && !model.chat.isRunning, let id = item.messageID {
                VStack(spacing: 6) {
                    Button { model.chat.beginEditing(id) } label: { Image(systemName: "pencil") }.help("Edit and resend")
                    if isLastUser { Button { model.chat.retryLast() } label: { Image(systemName: "arrow.clockwise") }.help("Retry") }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            VStack(alignment: .trailing, spacing: 4) {
                if !item.attachmentNames.isEmpty {
                    Text(item.attachmentNames.map { "📎 \($0)" }.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary)
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
                }
                if item.viaVoice {
                    Label("voice", systemImage: "waveform").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.thinking.isEmpty {
                DisclosureGroup("Thinking") {
                    Text(item.thinking)
                        .font(.system(size: textSize - 1))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !item.text.isEmpty {
                MarkdownView(text: item.text).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if item.isStreaming { ProgressView().controlSize(.small) }
                if let model = item.model, !item.isStreaming {
                    Text(model).font(.caption2).foregroundStyle(.tertiary)
                }
                if hovering && !item.isStreaming && !item.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption2)
                }
            }
        }
    }

    private func tool(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { showDetail.toggle() } label: {
                HStack(spacing: 6) {
                    toolIcon
                    Text(item.text.isEmpty ? name : item.text).font(.system(size: textSize - 1, design: .monospaced)).lineLimit(1)
                    Image(systemName: showDetail ? "chevron.down" : "chevron.right").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showDetail && !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(40)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            }
        }
    }

    @ViewBuilder private var toolIcon: some View {
        switch item.toolState {
        case .pending, .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
        }
    }
}

/// While Voice Mode is on: what it's doing, what it heard, and its controls.
struct VoiceModeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let voice = model.voice!
        @Bindable var app = model
        HStack(spacing: 10) {
            switch voice.state {
            case .listening:
                LevelMeter(level: voice.scripted != nil ? 0.5 : voice.level)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.partial.isEmpty ? listeningHint(voice) : "“\(voice.partial)”")
                        .foregroundStyle(voice.partial.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                    if voice.partial.isEmpty, !voice.lastAction.isEmpty {
                        Text(voice.lastAction).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .thinking:
                ProgressView().controlSize(.small)
                Text("Working on “\(voice.heard)”…").foregroundStyle(.secondary).lineLimit(2)
            case .speaking:
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative)
                Text("Speaking (mic muted)").foregroundStyle(.secondary)
                Button("Stop Talking") { voice.stopTalking() }.controlSize(.small)
            case .off:
                EmptyView()
            }
            Spacer()
            Menu {
                Toggle("Say Replies Out Loud", isOn: $app.settings.speakReplies)
                Toggle("Always Need “\(model.settings.wakeWord)”", isOn: $app.settings.alwaysNeedWakeWord)
                Divider()
                Text("Try: “Next slide”, “Start recording”, “Go to slide 3”, “Stop recording”, “Stop listening”")
            } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button { voice.stop() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Turn off Voice Mode")
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private func listeningHint(_ voice: VoiceMode) -> String {
        voice.needsWakeWord
            ? "Listening for “\(model.settings.wakeWord), …” (recording or live: other speech is ignored)"
            : "Listening… say “next slide”, “start recording”, or ask anything"
    }
}

private struct ChatTextSizeKey: EnvironmentKey {
    static let defaultValue: Double = 14
}

extension EnvironmentValues {
    /// The chat's text size (Settings › Chat, ⌘+ / ⌘−).
    var chatTextSize: Double {
        get { self[ChatTextSizeKey.self] }
        set { self[ChatTextSizeKey.self] = newValue }
    }
}
