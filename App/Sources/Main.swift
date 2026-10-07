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

/// Receives .snazzy files opened from Finder, AirDrop or Mail.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openHandler: (([URL]) -> Void)? {
        didSet { if let openHandler, !pending.isEmpty { openHandler(pending); pending = [] } }
    }
    @MainActor private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let handler = Self.openHandler { handler(urls) } else { Self.pending += urls }
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
                    AppDelegate.openHandler = { urls in
                        for url in urls where url.pathExtension.lowercased() == SnazzyShare.fileExtension { sharing.open(url) }
                    }
                    #if DEBUG
                    if UserDefaults.standard.bool(forKey: "SnazzyPro.debugShareSheet") { sharing.beginExport() }
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
        }
        CommandGroup(after: .help) {
            Button("Snazzy Pro for Developers") { openWindow(id: "developer-help") }
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
            ForEach(Array(AssistantTask.allCases.enumerated()), id: \.element) { index, task in
                Button("Use \(task.displayName) Model") { model.settings.activeTask = task }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
        }
    }
}
