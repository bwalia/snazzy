import AppKit
import SnazzyCore
import SwiftUI

/// Entry point. `--self-test` runs headless checks (Keychain, providers)
/// inside the sandboxed app and exits; otherwise the normal UI starts.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in
                let ok = await SelfTest.run(arguments: CommandLine.arguments)
                exit(ok ? 0 : 1)
            }
            dispatchMain()
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
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") { model.chat.clear() }
                .keyboardShortcut("n")
                .disabled(model.chat.isRunning)
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
