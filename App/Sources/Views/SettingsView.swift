import Assistant
import SnazzyCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelsSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
            ProvidersSettings()
                .tabItem { Label("Providers", systemImage: "network") }
            ChatSettings()
                .tabItem { Label("Chat & Voice", systemImage: "waveform") }
            MCPSettings()
                .tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
            DeveloperSettingsView()
                .tabItem { Label("Developer", systemImage: "hammer") }
        }
        .frame(width: 680, height: 560)
    }
}

/// Provider and model per task.
struct ModelsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(AssistantTask.allCases) { task in
                    TaskModelRow(task: task)
                }
            } footer: {
                Text("Use Test connection on the Providers tab to list installed or available models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TaskModelRow: View {
    @Environment(AppModel.self) private var model
    let task: AssistantTask

    var body: some View {
        let selection = model.settings.selection(for: task)
        LabeledContent(task.displayName) {
            HStack {
                Picker("Provider", selection: providerBinding) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                TextField("Model", text: modelBinding)
                    .frame(minWidth: 160)
                Menu {
                    let known = knownModels(selection.provider)
                    if known.isEmpty { Text("No models yet: test the connection") }
                    ForEach(known, id: \.self) { id in Button(id) { modelBinding.wrappedValue = id } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                LocationBadge(provider: selection.provider, sending: false)
            }
        }
    }

    private func knownModels(_ provider: ProviderKind) -> [String] {
        let discovered = model.discoveredModels[provider]?.filter { $0.supportsTools != false }.map(\.id) ?? []
        var seen = Set<String>()
        return (provider.suggestedModels + discovered).filter { seen.insert($0).inserted }
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding {
            model.settings.selection(for: task).provider
        } set: { newValue in
            guard newValue != model.settings.selection(for: task).provider else { return }
            let defaultModel = knownModels(newValue).first ?? ""
            model.settings.setSelection(ModelSelection(provider: newValue, model: defaultModel), for: task)
        }
    }

    private var modelBinding: Binding<String> {
        Binding {
            model.settings.selection(for: task).model
        } set: { newValue in
            var selection = model.settings.selection(for: task)
            selection.model = newValue.trimmingCharacters(in: .whitespaces)
            model.settings.setSelection(selection, for: task)
        }
    }
}

struct ProvidersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var anthropicKey = ""
    @State private var keyError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                if let reason = AppleOnDeviceProvider.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Label("Ready. Runs on this Mac: no key, no network, nothing leaves your computer.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Text("Best for quick commands and device setup. It has a small memory, so use a larger model for long writing or big prototypes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use for All Tasks") {
                    let apple = ModelSelection(provider: .appleOnDevice, model: ProviderKind.appleModelID)
                    for task in AssistantTask.allCases { model.settings.setSelection(apple, for: task) }
                }
                .disabled(!AppleOnDeviceProvider.isAvailable)
            } header: {
                HStack {
                    Text("Apple Intelligence")
                    LocationBadge(provider: .appleOnDevice, sending: false)
                }
            }

            Section {
                LabeledContent("API key") {
                    HStack {
                        SecureField(model.storedKeys.contains(.anthropic) ? "Stored in Keychain" : "sk-ant-…", text: $anthropicKey)
                            .textContentType(.password)
                        Button("Save") { saveKey() }
                            .disabled(anthropicKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        if model.storedKeys.contains(.anthropic) {
                            Button("Remove", role: .destructive) { removeKey() }
                        }
                    }
                }
                if model.storedKeys.contains(.anthropic) {
                    Label("Key stored in the macOS Keychain", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
                TextField("Base URL", text: $model.settings.anthropicBaseURL)
                Picker("Effort", selection: $model.settings.anthropicEffort) {
                    ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                }
                ConnectionTestRow(provider: .anthropic)
            } header: {
                HStack {
                    Text("Anthropic")
                    LocationBadge(provider: .anthropic, sending: false)
                }
            }

            Section {
                TextField("Base URL", text: $model.settings.ollamaBaseURL)
                ConnectionTestRow(provider: .ollama)
            } header: {
                HStack {
                    Text("Ollama")
                    LocationBadge(provider: .ollama, sending: false)
                }
            } footer: {
                Text("OpenAI-compatible and LM Studio providers come in a later phase.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func saveKey() {
        do {
            try model.saveAPIKey(anthropicKey, for: .anthropic)
            anthropicKey = ""
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try model.deleteAPIKey(for: .anthropic)
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }
}

struct ConnectionTestRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, testing
        case ok(String)
        case failed(String)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button("Test connection") { Task { await test() } }
                .disabled(status == .testing)
            switch status {
            case .idle: EmptyView()
            case .testing: ProgressView().controlSize(.small)
            case .ok(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
            }
        }
        .font(.callout)
    }

    private func test() async {
        if let reason = model.unavailableReason(provider) {
            status = .failed(reason)
            return
        }
        status = .testing
        switch await model.testConnection(provider) {
        case .success(let models):
            let toolModels = models.filter { $0.supportsTools != false }.count
            status = .ok("Connected: \(models.count) models (\(toolModels) with tool support)")
        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
    }
}

struct ChatSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Text") {
                HStack {
                    Slider(value: $model.settings.chatTextSize, in: AppSettings.chatTextSizes, step: 1) { Text("Chat text size") }
                    Text("\(Int(model.settings.chatTextSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("Also ⌘+ and ⌘− in the chat, ⌘0 to reset.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Voice Mode") {
                Toggle("Say replies out loud", isOn: $model.settings.speakReplies)
                Picker("Voice", selection: $model.settings.voiceIdentifier) {
                    Text("Best for my language").tag("")
                    ForEach(VoiceMode.voices(), id: \.identifier) { v in
                        Text("\(v.name)\(v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : "")").tag(v.identifier)
                    }
                }
                HStack {
                    Slider(value: $model.settings.speechRate, in: 0.3...0.65) { Text("Speed") }
                    Button("Test") { Task { await model.voice.speak("Hi, I'm Snazzy. Say next slide, start recording, or ask me anything.") } }
                }
                TextField("Wake word", text: $model.settings.wakeWord)
                Toggle("Always need the wake word", isOn: $model.settings.alwaysNeedWakeWord)
                Text("Voice Mode (⌥⌘V, or the waveform button next to the mic) is a hands-free conversation. Short commands like “next slide”, “go to slide 3”, “start recording” and “stop recording” happen straight away, even without AI; anything else goes to the assistant, which can run your slides, recording, prompter and live room. While it speaks, the mic is muted, so its voice isn't recorded or streamed. While you're recording, live or streaming, start with the wake word (“\(model.settings.wakeWord), next slide”) so talking to your audience isn't taken as a command. Better voices: System Settings › Accessibility › Spoken Content › System Voice › Manage Voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Voice messages") {
                Toggle("Send voice messages as soon as I stop talking", isOn: $model.settings.voiceAutoSend)
                Text("Otherwise the transcript goes into the message box so you can check it first. Speech is transcribed on this Mac when the language supports it. Uses the microphone chosen in Sources.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Session record") {
                Toggle("Keep a record of each session", isOn: $model.settings.recordSessions)
                Text("Messages, tool calls, builder steps and voice clips are saved with timestamps in Movies › Snazzy Pro › Sessions. Screen and camera video of a session aren't included; use Record for that.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Sessions Folder") {
                    try? FileManager.default.createDirectory(at: SessionLog.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([SessionLog.root])
                }
            }
            Section("Cloud AI") {
                if model.settings.cloudConsent.isEmpty {
                    Text("You haven't allowed any cloud provider yet. You'll be asked before anything is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Allowed", value: model.settings.cloudConsent.compactMap { ProviderKind(rawValue: $0)?.displayName }.joined(separator: ", "))
                    Button("Withdraw Permission") { model.settings.cloudConsent = [] }
                    Text("You'll be asked again before the next message goes to a cloud provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Limits") {
                Stepper("Max reply length: \(model.settings.maxOutputTokens.formatted()) tokens",
                        value: $model.settings.maxOutputTokens, in: 4_000...128_000, step: 4_000)
                Text("Building larger prototypes needs room: 32,000 or more is recommended.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
