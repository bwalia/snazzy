import AppKit
import SnazzyCore
import SwiftUI

/// Entry point. `--self-test` runs headless checks (Keychain, providers)
/// inside the sandboxed app and exits; otherwise the normal UI starts.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            // Same AppKit main run loop as the real app (dispatchMain() leaves
            // main-actor work running off the main thread, which breaks AppKit).
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let ok = await SelfTest.run(arguments: CommandLine.arguments)
                exit(ok ? 0 : 1)
            }
            app.run()
        } else {
            SnazzyProApp.main()
        }
    }
}

struct SnazzyProApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Snazzy Pro", id: "main") {
            MainView()
                .environment(model)
                .environment(model.capture)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(model: model) }

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
        CommandMenu("Devices") {
            Button("Open Inset Preview") { try? model.capture.openPreview() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.capture.setup.insetDevice == nil)
            Button("Close Previews") { model.capture.closePreview() }
                .disabled(model.capture.openPreviewIDs.isEmpty)
            Divider()
            Button("Refresh Devices") { Task { await model.capture.catalog.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Assistant") {
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
