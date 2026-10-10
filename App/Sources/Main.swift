import AppKit
import Builder
import SnazzyCore
import SwiftUI

/// Entry point. `--self-test` runs headless checks (Keychain, providers)
/// inside the sandboxed app and exits; otherwise the normal UI starts.
@main
enum Main {
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--self-test") {
            setvbuf(stdout, nil, _IONBF, 0)
            print("Snazzy Pro self-test (\(Bundle.main.bundleIdentifier ?? "?"))")
            // Same AppKit main run loop as the real app (dispatchMain() leaves
            // main-actor work running off the main thread, which breaks AppKit).
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let ok = await SelfTest.run(arguments: CommandLine.arguments)
                exit(ok ? 0 : 1)
            }
            app.run()
            return
        }
        #endif
        SnazzyProApp.main()
    }
}

/// Receives .snazzy files opened from Finder, AirDrop or Mail, and finishes a
/// recording before the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openHandler: (([URL]) -> Void)? {
        didSet { if let openHandler, !pending.isEmpty { openHandler(pending); pending = [] } }
    }
    @MainActor private static var pending: [URL] = []
    @MainActor static var capture: CaptureController?

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let handler = Self.openHandler { handler(urls) } else { Self.pending += urls }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let capture = Self.capture, capture.recorder.isActive else { return .terminateNow }
            Task { @MainActor in
                await capture.stopRecording()
                // A stop already in progress: wait for the movie to be saved.
                while capture.recorder.isActive { try? await Task.sleep(for: .milliseconds(100)) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

struct SnazzyProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Snazzy Pro", id: "main") {
            MainView()
                .environment(model)
                .environment(model.capture)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    let sharing = model.sharing!
                    AppDelegate.capture = model.capture
                    AppDelegate.openHandler = { urls in
                        for url in urls where url.pathExtension.lowercased() == SnazzyShare.fileExtension { sharing.open(url) }
                    }
                    #if DEBUG
                    if UserDefaults.standard.bool(forKey: "SnazzyPro.debugShareSheet") { sharing.beginExport() }
                    if UserDefaults.standard.bool(forKey: "SnazzyPro.screenshots") {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            await Screenshots.run(app: model)
                        }
                    }
                    if let tour = UserDefaults.standard.string(forKey: "SnazzyPro.tour") {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            await Tours.run(tour, app: model)
                        }
                    }
                    if let topic = UserDefaults.standard.string(forKey: "SnazzyPro.debugStartLive") {
                        model.live.pendingTopic = topic
                        Task { await model.live.start() }
                    }
                    #endif
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(model: model) }

        Window("For Developers", id: "developer-help") {
            DeveloperHelpView()
                .environment(model)
        }
        .defaultSize(width: 600, height: 640)

        Window("iPhone & iPad Remote", id: "remote") {
            RemoteWindow()
                .environment(model)
        }
        .defaultSize(width: 620, height: 560)

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environment(model.capture)
        }
        .defaultSize(width: 760, height: 420)
        .keyboardShortcut("d", modifiers: [.command, .option])

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { model.chat.clear() }
                .keyboardShortcut("n")
                .disabled(model.chat.isRunning)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Share…") { model.sharing.beginExport() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Import Shared File…") { model.sharing.chooseFileToImport() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Find in Slides…") { model.findInSlides() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Get Decks from GitHub…") {
                model.sidePanelTab = .slides
                model.slidesMode = .github
            }
        }
        CommandMenu("Devices") {
            Button("Open Inset Preview") { try? model.capture.openPreview() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.capture.setup.insetDevice == nil)
            Button("Open Recording Preview") { model.capture.openCompositePreview() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Close Previews") {
                model.capture.closePreview()
                model.capture.closeCompositePreview()
            }
                .disabled(model.capture.openPreviewIDs.isEmpty && !model.capture.compositePreviewOpen)
            Divider()
            Button("Refresh Devices") { Task { await model.capture.catalog.refresh() } }
            Divider()
            Button("iPhone & iPad Remote…") { openWindow(id: "remote") }
        }
        CommandGroup(after: .help) {
            Button("Snazzy Pro for Developers") { openWindow(id: "developer-help") }
            Button("Terms of Use") { NSWorkspace.shared.open(Legal.termsURL) }
            Button("Privacy Policy") { NSWorkspace.shared.open(Legal.privacyURL) }
            Button("Acknowledgements") {
                if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") { NSWorkspace.shared.open(url) }
            }
        }
        CommandMenu("Presets") {
            Button("Save Current Settings…") { model.presets.promptAndSave() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            if model.presets.presets.isEmpty {
                Text("No presets yet")
            }
            ForEach(model.presets.presets) { preset in
                Button((preset.name == model.presets.activeName ? "✓ " : "") + preset.name) {
                    _ = try? model.presets.load(preset.name)
                }
            }
            Divider()
            Menu("Delete Preset") {
                ForEach(model.presets.presets) { preset in
                    Button(preset.name) {
                        let alert = NSAlert()
                        alert.messageText = "Delete preset “\(preset.name)”?"
                        alert.addButton(withTitle: "Delete")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { try? model.presets.delete(preset.name) }
                    }
                }
            }
            .disabled(model.presets.presets.isEmpty)
            Button("Show Presets Folder") { model.presets.revealFolder() }
        }
        CommandMenu("Record") {
            let recorder = model.capture.recorder
            if recorder.isActive {
                Button("Stop Recording") { Task { await model.capture.stopRecording() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            } else {
                Button("Start Recording") { Task { try? await model.capture.startRecording() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            Button(recorder.state == .paused ? "Resume Recording" : "Pause Recording") {
                if recorder.state == .paused { model.capture.resumeRecording() } else { model.capture.pauseRecording() }
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            .disabled(recorder.state != .recording && recorder.state != .paused)
            Divider()
            Button("Next Slide") { model.builder.nextSlide() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.builder.isDeckOpen)
            Button("Previous Slide") { model.builder.previousSlide() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!model.builder.isDeckOpen)
            Button("Open Present Window") { model.builder.openPopOut() }
                .disabled(!model.builder.isDeckOpen)
            Divider()
            Button(model.prompter.isShown ? "Hide Camera Prompter" : "Show Camera Prompter") { model.prompter.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button(model.prompter.isScrolling ? "Pause Prompter" : "Start Prompter") { model.prompter.toggleScrolling() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.prompter.isShown)
            Divider()
            Button("Reset Zoom") { model.capture.animateZoom(to: nil) }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(model.capture.screenZoom == nil)
        }
        CommandMenu("Assistant") {
            Button("Explain Front Window") { model.chat.send("Explain what's in my front window.") }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.developer.settings.screenReadingEnabled || model.chat.isRunning)
            Divider()
            Button("Stop Generating") { model.chat.stop() }
                .keyboardShortcut(".")
                .disabled(!model.chat.isRunning)
            Divider()
            Button(model.voice.isOn ? "Turn Off Voice Mode" : "Voice Mode") { model.voice.toggle() }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Stop Talking") { model.voice.stopTalking() }
                .disabled(model.voice.state != .speaking)
            Divider()
            Button("Larger Chat Text") { model.settings.chatTextSize = min(AppSettings.chatTextSizes.upperBound, model.settings.chatTextSize + 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Chat Text") { model.settings.chatTextSize = max(AppSettings.chatTextSizes.lowerBound, model.settings.chatTextSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size Chat Text") { model.settings.chatTextSize = AppSettings.default.chatTextSize }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            ForEach(Array(AssistantTask.allCases.enumerated()), id: \.element) { index, task in
                Button("Use \(task.displayName) Model") { model.settings.activeTask = task }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
        }
    }
}
