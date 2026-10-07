import SnazzyCore
import SwiftUI

/// Current task/model, local vs cloud, token use, and a clear indicator while
/// content is being sent to a cloud provider.
struct ChatHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let selection = model.activeSelection
        let chat = model.chat!

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Task", selection: $model.settings.activeTask) {
                    ForEach(AssistantTask.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Which model setting the chat uses (⌥⌘1–3)")

                VStack(alignment: .leading, spacing: 1) {
                    Text(selection.model).font(.callout.weight(.medium)).lineLimit(1)
                    Text(selection.provider.displayName).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                LocationBadge(provider: selection.provider, sending: chat.activeProvider == selection.provider && chat.isRunning)

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Model and provider settings")

                Button {
                    chat.clear()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .disabled(chat.isRunning)
                .help("New conversation (⌘N)")
            }

            HStack(spacing: 10) {
                Label("\(chat.sessionUsage.inputTokens.formatted()) in · \(chat.sessionUsage.outputTokens.formatted()) out",
                      systemImage: "number")
                    .help("Tokens used in this conversation")
                if let preset = model.presets.activeName {
                    Label(preset, systemImage: "slider.horizontal.3").lineLimit(1).help("Active settings preset (Presets menu)")
                }
                if let reason = model.unavailableReason(selection.provider) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct LocationBadge: View {
    let provider: ProviderKind
    let sending: Bool

    var body: some View {
        let local = provider.isLocal
        HStack(spacing: 4) {
            Image(systemName: local ? "desktopcomputer" : (sending ? "icloud.and.arrow.up.fill" : "cloud"))
                .symbolEffect(.pulse, isActive: sending && !local)
            Text(local ? "Local" : (sending ? "Sending to \(provider.displayName)" : "Cloud"))
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(local ? Color.green.opacity(0.18) : Color.orange.opacity(sending ? 0.35 : 0.18)))
        .foregroundStyle(local ? .green : .orange)
        .help(local ? "Runs on this Mac; nothing leaves the computer." : "Messages are sent to \(provider.displayName).")
        .accessibilityLabel(local ? "Local model" : (sending ? "Sending to cloud provider" : "Cloud model"))
    }
}
