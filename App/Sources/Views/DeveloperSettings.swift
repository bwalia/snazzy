import SnazzyCore
import SwiftUI

/// Settings › Developer: turn each developer feature on or off.
struct DeveloperSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dev = model.developer!
        Form {
            Section {
                Toggle("Trim recordings", isOn: binding(\.trimEnabled))
                Text("Cut the start or end of a take. Saves a new “(trimmed)” copy; the original is never changed.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Captions and summaries", isOn: binding(\.captionsEnabled))
                Text("Captions are made on this Mac (.srt and .vtt). Summaries use your Writing model; with a cloud model you see the exact text before it's sent. Audio and video are never sent.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Recordings") }
            DeveloperExtraSections()
        }
        .formStyle(.grouped)
        .onAppear { dev.refresh() }
    }

    private func binding(_ keyPath: WritableKeyPath<DeveloperSettings, Bool>) -> Binding<Bool> {
        Binding { model.developer.settings[keyPath: keyPath] } set: { model.developer.settings[keyPath: keyPath] = $0 }
    }
}

/// Sections added by later developer features.
struct DeveloperExtraSections: View {
    var body: some View { EmptyView() }
}
