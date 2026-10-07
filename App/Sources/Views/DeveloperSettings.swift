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
            DeveloperShareSection()
            DeveloperExtraSections()
        }
        .formStyle(.grouped)
        .onAppear { dev.refresh() }
    }

    private func binding(_ keyPath: WritableKeyPath<DeveloperSettings, Bool>) -> Binding<Bool> {
        Binding { model.developer.settings[keyPath: keyPath] } set: { model.developer.settings[keyPath: keyPath] = $0 }
    }
}

/// Pull-request demos and screen reading.
struct DeveloperExtraSections: View {
    @Environment(AppModel.self) private var model
    @State private var repos: [URL] = []

    var body: some View {
        let dev = model.developer!
        Section {
            Toggle("Demos from pull requests and branches", isOn: Binding(get: { dev.settings.pullRequestDemosEnabled }, set: { dev.settings.pullRequestDemosEnabled = $0 }))
            Text("Loads a PR's description and diff from GitHub so the assistant can plan a demo deck. Uses the GitHub token from Share (optional for public repositories). With a cloud model you see exactly what will be sent first.")
                .font(.caption).foregroundStyle(.secondary)
            if dev.settings.pullRequestDemosEnabled {
                Stepper("Cut diffs after \(dev.settings.maxDiffCharacters.formatted()) characters",
                        value: Binding(get: { dev.settings.maxDiffCharacters }, set: { dev.settings.maxDiffCharacters = $0 }),
                        in: 10_000...200_000, step: 10_000)
                LabeledContent("Local repositories") {
                    VStack(alignment: .trailing) {
                        ForEach(repos, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).font(.caption)
                                Button { dev.removeRepository(url); repos = dev.grantedRepositories } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Button("Add Repository…") { dev.grantRepository(); repos = dev.grantedRepositories }
                    }
                }
                Text("Local branches are compared through GitHub, so push them first. The App Store version can't run git itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Pull requests") }
        .onAppear { repos = dev.grantedRepositories }
        DeveloperScreenSection()
    }
}

/// Added by the screen-reading feature.
struct DeveloperScreenSection: View {
    var body: some View { EmptyView() }
}
