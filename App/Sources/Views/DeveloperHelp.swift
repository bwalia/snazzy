import SnazzyCore
import SwiftUI

/// Help › For Developers: what each developer feature does, with things to say.
struct DeveloperHelpView: View {
    @Environment(AppModel.self) private var model

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let enabled: (DeveloperSettings) -> Bool
        let detail: String
        let examples: [String]
    }

    static let items: [Item] = [
        Item(title: "Trim", enabled: { $0.trimEnabled }, detail: "Cut the start or end of a take. Saves a “(trimmed)” copy; the original stays untouched.",
             examples: ["Cut the first 5 seconds of my last recording.", "Trim the last bit where I stop the recording."]),
        Item(title: "Captions and summaries", enabled: { $0.captionsEnabled }, detail: "Captions made on this Mac (.srt, .vtt, optional burned-in copy) and a short summary with chapters.",
             examples: ["Make captions for my latest recording.", "Summarise my last recording."]),
        Item(title: "Share links", enabled: { $0.shareEnabled }, detail: "Upload to your own S3 bucket or GitHub and get a link plus text for Slack, a PR or Jira. You approve every upload.",
             examples: ["Share my latest recording to S3.", "Put the summary of my last recording in a Gist."]),
        Item(title: "Demos from pull requests", enabled: { $0.pullRequestDemosEnabled }, detail: "Loads a PR's description and diff and plans a 2–4 slide demo with a talk script.",
             examples: ["Make a demo of PR octocat/hello-world#42.", "Make a demo of my current branch compared with main."]),
        Item(title: "What's on screen", enabled: { $0.screenReadingEnabled || $0.zoomEnabled }, detail: "Reads your terminal or editor, and zooms the recording to an error. Secrets are hidden before anything goes to a cloud model.",
             examples: ["Explain what's in my terminal.", "Zoom in on the stack trace."]),
    ]

    var body: some View {
        let settings = model.developer.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("For developers").font(.title2.weight(.bold))
                Text("Turn each feature on or off in Settings › Developer. Everything works with a local model; with a cloud model you see exactly what would be sent first.")
                    .foregroundStyle(.secondary)
                ForEach(Self.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.title).font(.headline)
                            Text(item.enabled(settings) ? "On" : "Off").font(.caption.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(item.enabled(settings) ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15)))
                        }
                        Text(item.detail).font(.callout)
                        ForEach(item.examples, id: \.self) { e in
                            Button { model.chat.draft = e } label: { Label("“\(e)”", systemImage: "text.bubble") }
                                .buttonStyle(.borderless).font(.callout)
                        }
                    }
                }
                SettingsLink { Text("Open Settings…") }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 520)
    }
}
