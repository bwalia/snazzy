import Builder
import SnazzyCore
import SwiftUI
import WebKit

/// What the builder agent is making: live preview on top, files / code /
/// steps / console below. Code streams in as the model writes it.
struct BuilderPanel: View {
    @Environment(AppModel.self) private var model
    @State private var bottomTab: BottomTab = .code
    @State private var askingPR = false
    @State private var editing: DeckOutline?
    @State private var editingNew = false
    @State private var prRef = ""

    enum BottomTab: String, CaseIterable { case code = "Code", steps = "Steps", console = "Console" }

    var body: some View {
        let builder = model.builder
        VStack(spacing: 0) {
            header(builder)
                .sheet(isPresented: $askingPR) { prSheet }
                .sheet(item: Binding(get: { editing.map(EditingDeck.init) }, set: { if $0 == nil { editing = nil } })) { item in
                    DeckEditorView(outline: item.outline, isNew: editingNew, onSave: { o in
                        if editingNew { try? builder.createDeck(o) } else { try? builder.saveDeck(o) }
                        editing = nil
                    }, onCancel: { editing = nil })
                }
            Divider()
            if builder.current == nil {
                ContentUnavailableView {
                    Label("Nothing built yet", systemImage: "hammer")
                } description: {
                    Text("Ask the assistant to build something, e.g. “Build a clickable prototype of a DevOps dashboard” or “Make a 6-slide deck on our Q3 results”.")
                } actions: {
                    Button("Make a Deck") { editingNew = true; editing = .starter(title: "My Presentation") }
                        .buttonStyle(.borderedProminent)
                    Button("New Prototype") { _ = try? builder.createProject(name: "prototype", kind: .prototype, title: "Prototype") }
                }
            } else {
                VSplitView {
                    WebPreview(webView: builder.webView)
                        .frame(minHeight: 200, idealHeight: 420)
                        .overlay(alignment: .topTrailing) {
                            if builder.isLoading { ProgressView().controlSize(.small).padding(8) }
                        }
                    bottom(builder)
                        .frame(minHeight: 160, idealHeight: 260)
                }
            }
        }
    }

    private var prSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Demo from a pull request").font(.headline)
            TextField("owner/repo#123 or the PR's URL", text: $prRef).frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { askingPR = false }
                Button("Make Demo") {
                    model.chat.send("Make a demo of pull request \(prRef): load it, plan a 2–4 slide demo deck (what changed, why, how to test) with a short talk script, then ask me whether to record.")
                    askingPR = false
                    prRef = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(GitRefs.parse(prRef)?.number == nil)
            }
        }
        .padding(20)
    }

    private func header(_ builder: BuilderController) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(builder.projects) { p in
                    Button("\(p.name) (\(p.kind.rawValue))") { builder.open(p.name) }
                }
                Divider()
                Button("New Deck (Slide Editor)…") { editingNew = true; editing = .starter(title: "My Presentation") }
                if let o = builder.outline {
                    Button("Edit Slides…") { editingNew = false; editing = o }
                }
                Divider()
                Button("New Prototype") { _ = try? builder.createProject(name: "prototype-\(Int(Date().timeIntervalSince1970) % 10000)", kind: .prototype, title: "Prototype") }
                Button("New Presentation") { _ = try? builder.createProject(name: "deck-\(Int(Date().timeIntervalSince1970) % 10000)", kind: .presentation, title: "Presentation") }
                if model.developer.settings.pullRequestDemosEnabled {
                    Divider()
                    Button("Demo from Pull Request…") { askingPR = true }
                    Button("Demo from Local Branch…") {
                        if let folder = model.developer.grantRepository() {
                            model.chat.send("Make a demo of the changes on the current branch of my \(folder.lastPathComponent) repository compared with main: load them, plan a 2–4 slide demo deck with a short talk script, then ask me whether to record.")
                        }
                    }
                }
            } label: {
                Label(builder.current?.name ?? "Projects", systemImage: builder.current?.kind == .presentation ? "play.rectangle" : "app.dashed")
            }
            .fixedSize()
            if builder.current?.shared == true {
                Menu {
                    Button("Allow Internet for This Project") { builder.allowInternet() }
                } label: {
                    Label("Offline", systemImage: "wifi.slash")
                }
                .fixedSize()
                .help("This project came from someone else, so its pages can't reach the internet or send anything out.")
            }
            if let live = builder.live {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Writing \(live.path)… \(live.content.count.formatted()) chars").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { builder.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload preview").disabled(builder.current == nil)
            Button { builder.openPopOut() } label: { Image(systemName: "macwindow.on.rectangle") }
                .help("Open the result in its own window").disabled(builder.current == nil)
            Button { model.sharing.beginExport(project: builder.current?.name) } label: { Image(systemName: "square.and.arrow.up") }
                .help("Share this project with another Snazzy Pro user")
                .disabled(builder.current == nil)
            Button { builder.revealInFinder() } label: { Image(systemName: "folder") }
                .help("Show the project files in Finder").disabled(builder.current == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private func bottom(_ builder: BuilderController) -> some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $bottomTab) {
                    ForEach(BottomTab.allCases, id: \.self) { tab in
                        Text(tab == .console && !builder.console.filter({ $0.level == "error" }).isEmpty ? "Console ⚠︎" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(6)
            Divider()
            switch bottomTab {
            case .code: CodePane(builder: builder)
            case .steps: StepsPane(builder: builder)
            case .console: ConsolePane(builder: builder)
            }
        }
        .onChange(of: builder.live?.callID) { _, new in if new != nil { bottomTab = .code } }
    }
}

struct WebPreview: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private struct CodePane: View {
    let builder: BuilderController

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { builder.live?.path ?? builder.selectedFile }, set: { builder.selectedFile = $0 })) {
                ForEach(builder.files, id: \.self) { file in
                    Label(file, systemImage: icon(file)).font(.callout).tag(file)
                }
                if let live = builder.live, !builder.files.contains(live.path) {
                    Label(live.path, systemImage: "pencil").font(.callout).foregroundStyle(.orange).tag(live.path)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 170)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(builder.live?.content ?? builder.selectedContent)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(10)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .onChange(of: builder.live?.content) { _, _ in proxy.scrollTo("end", anchor: .bottomLeading) }
            }
        }
    }

    private func icon(_ file: String) -> String {
        switch (file as NSString).pathExtension {
        case "html": "chevron.left.forwardslash.chevron.right"
        case "css": "paintbrush"
        case "js": "curlybraces"
        case "json": "doc.text"
        case "svg", "png", "jpg": "photo"
        default: "doc"
        }
    }
}

private struct StepsPane: View {
    let builder: BuilderController

    var body: some View {
        List(builder.steps.reversed()) { step in
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon(step.kind)).foregroundStyle(color(step.kind))
                Text(step.text).font(.callout).textSelection(.enabled)
                Spacer()
                Text(step.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func icon(_ k: BuilderController.Step.Kind) -> String {
        switch k {
        case .info: "info.circle"
        case .writing: "pencil"
        case .wrote: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private func color(_ k: BuilderController.Step.Kind) -> Color {
        switch k {
        case .info: .secondary
        case .writing: .orange
        case .wrote: .green
        case .error: .red
        }
    }
}

private struct ConsolePane: View {
    let builder: BuilderController

    var body: some View {
        if builder.console.isEmpty {
            Text("No console output.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(builder.console) { entry in
                Text(entry.message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(entry.level == "error" ? .red : entry.level == "warn" ? .orange : .primary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Wraps an outline for `.sheet(item:)`.
private struct EditingDeck: Identifiable {
    let id = UUID()
    let outline: DeckOutline
}
