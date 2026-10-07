import Assistant
import SnazzyCore
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader()
            Divider()
            transcript
            Divider()
            composer
        }
        .background(.background)
        .onAppear { inputFocused = true }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.chat.transcript.isEmpty {
                        EmptyChatHint()
                    }
                    ForEach(model.chat.transcript) { item in
                        TranscriptRow(item: item).id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: model.chat.transcript) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Snazzy… (⏎ to send, ⇧⏎ for a new line)", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            if model.chat.isRunning {
                Button(action: model.chat.stop) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Stop generating (⌘.)")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
        .padding(10)
    }

    private func send() {
        if model.chat.send(input) { input = "" }
    }
}

struct EmptyChatHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What are we making?").font(.title3.weight(.semibold))
            Text("Try: “Make a 5-minute presentation on our Q3 DevOps results for the leadership team.”")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    @State private var showDetail = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !item.thinking.isEmpty {
                    DisclosureGroup("Thinking") {
                        Text(item.thinking)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !item.text.isEmpty {
                    Text(markdown(item.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.isStreaming {
                    ProgressView().controlSize(.small)
                }
                if let model = item.model, !item.isStreaming {
                    Text(model).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        case .tool(let name):
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    showDetail.toggle()
                } label: {
                    HStack(spacing: 6) {
                        toolIcon
                        Text(name).font(.callout.monospaced())
                        Image(systemName: showDetail ? "chevron.down" : "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showDetail && !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                }
            }
        case .notice(let isError):
            Label(item.text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.callout)
                .foregroundStyle(isError ? .red : .secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var toolIcon: some View {
        switch item.toolState {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}
