import Builder
import SnazzyCore
import SwiftUI
import WebKit

/// Talk, build and present on the iPad (or iPhone): the chat beside a live
/// preview of the deck or prototype the assistant is building.
struct StudioView: View {
    @Environment(StudioModel.self) private var studio
    @Environment(\.horizontalSizeClass) private var size
    @State private var showSettings = false
    @State private var showSamples = false
    @State private var presenting = false
    @State private var pane = 0
    @State private var editing: DeckOutline?
    @State private var editingNew = false

    var body: some View {
        NavigationStack {
            Group {
                if size == .regular {
                    HStack(spacing: 0) {
                        ChatPane().frame(width: 400)
                        Divider()
                        PreviewPane(present: { presenting = true })
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("", selection: $pane) {
                            Text("Chat").tag(0)
                            Text("Preview").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal).padding(.vertical, 8)
                        if pane == 0 { ChatPane() } else { PreviewPane(present: { presenting = true }) }
                    }
                }
            }
            .navigationTitle(studio.preview.current?.name ?? "Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Menu {
                        ForEach(studio.preview.projects) { p in
                            Button(p.name) { studio.preview.open(p.name) }
                        }
                        Divider()
                        Button { editingNew = true; editing = .starter(title: "My Presentation") } label: { Label("New Deck…", systemImage: "plus.rectangle.on.rectangle") }
                        if let o = studio.preview.outline {
                            Button { editingNew = false; editing = o } label: { Label("Edit Slides…", systemImage: "pencil") }
                        }
                        Button { showSamples = true } label: { Label("Sample Decks…", systemImage: "square.grid.2x2") }
                    } label: { Label("Projects", systemImage: "folder") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { studio.newConversation() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                        .disabled(studio.isRunning)
                    Button { showSettings = true } label: { Label("AI Settings", systemImage: "cpu") }
                }
            }
            .sheet(isPresented: $showSettings) { StudioSettings().environment(studio) }
            .sheet(isPresented: $showSamples) { SamplesSheet().environment(studio) }
            .fullScreenCover(isPresented: $presenting) { PresentMode().environment(studio) }
            .sheet(item: Binding(get: { editing.map(EditingDeck.init) }, set: { if $0 == nil { editing = nil } })) { item in
                DeckEditorView(outline: item.outline, isNew: editingNew, onSave: { o in
                    if editingNew { try? studio.preview.createDeck(o) } else { try? studio.preview.saveDeck(o) }
                    editing = nil
                }, onCancel: { editing = nil })
            }
            .environment(\.makeDeck, { editingNew = true; editing = .starter(title: "My Presentation") })
            #if DEBUG
            // Tests: `simctl launch … -studioNewDeck YES`
            .task { if UserDefaults.standard.bool(forKey: "studioNewDeck") { editingNew = true; editing = .starter(title: "My Presentation") } }
            #endif
        }
    }
}

private struct ChatPane: View {
    @Environment(StudioModel.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if studio.items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("What are we making?").font(.title3.bold())
                                ForEach(["Make a 5-slide deck about our new product for the sales team.",
                                         "A lesson on the water cycle for 10-year-olds, with a quiz.",
                                         "Turn these notes into a short talk with speaker notes."], id: \.self) { s in
                                    Button { studio.draft = s } label: { Text("“\(s)”").multilineTextAlignment(.leading) }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 8)
                        }
                        ForEach(studio.items) { item in
                            bubble(item).id(item.id)
                        }
                        if studio.isRunning { ProgressView().padding(.leading, 6) }
                    }
                    .padding()
                }
                .onChange(of: studio.items.last?.text) { _, _ in
                    if let id = studio.items.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Ask Snazzy…", text: $studio.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { studio.send() }
                if studio.isRunning {
                    Button { studio.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                } else {
                    Button { studio.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(studio.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(10)
            Text(studio.provider == .appleOnDevice ? "On-device AI · nothing leaves your iPad" : "\(studio.provider.displayName) · \(studio.model)")
                .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 6)
        }
    }

    @ViewBuilder private func bubble(_ item: StudioModel.Item) -> some View {
        switch item.kind {
        case .user:
            Text(item.text).padding(10)
                .background(Color.accentColor.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text(LocalizedStringKey(item.text)).padding(.vertical, 2)
        case .tool:
            Label(item.text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .note:
            Label(item.text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        }
    }
}

private struct PreviewPane: View {
    @Environment(StudioModel.self) private var studio
    @Environment(\.makeDeck) private var makeDeck
    var present: () -> Void

    var body: some View {
        let p = studio.preview
        VStack(spacing: 0) {
            if p.current == nil {
                ContentUnavailableView {
                    Label("Nothing to show yet", systemImage: "rectangle.on.rectangle")
                } description: {
                    Text("Ask the assistant for a deck, make one yourself in the slide editor, or open a sample from Projects.")
                } actions: {
                    Button("Make a Deck") { makeDeck() }.buttonStyle(.borderedProminent)
                }
            } else {
                WebPreview(webView: p.webView)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding()
                if p.isDeck {
                    HStack(spacing: 14) {
                        Button { p.previous() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 32) }
                            .buttonStyle(.bordered).disabled(p.currentSlide == 0)
                        Text("Slide \(p.currentSlide + 1) of \(p.slides.count)").monospacedDigit()
                        Button { p.next() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 32) }
                            .buttonStyle(.bordered).disabled(p.currentSlide >= p.slides.count - 1)
                        Spacer()
                        Button(action: present) { Label("Present", systemImage: "play.rectangle.fill") }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal)
                    let notes = p.slides.indices.contains(p.currentSlide) ? p.slides[p.currentSlide].notes : ""
                    ScrollView {
                        Text(notes.isEmpty ? "No speaker notes for this slide." : notes)
                            .foregroundStyle(notes.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                } else {
                    Spacer()
                }
                if !p.consoleErrors.isEmpty {
                    Label("\(p.consoleErrors.count) error(s) in the page: \(p.consoleErrors[0])", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal).padding(.bottom, 8)
                }
            }
        }
    }
}

/// Full-screen slides; tap the right or left side (or swipe) to move, notes at the bottom.
private struct PresentMode: View {
    @Environment(StudioModel.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @State private var showNotes = true

    var body: some View {
        let p = studio.preview
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            WebPreview(webView: p.webView)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { p.previous() }
                        Color.clear.contentShape(Rectangle()).onTapGesture { p.next() }
                    }
                }
                .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                    if v.translation.width < 0 { p.next() } else { p.previous() }
                })
            if showNotes, p.slides.indices.contains(p.currentSlide), !p.slides[p.currentSlide].notes.isEmpty {
                Text(p.slides[p.currentSlide].notes)
                    .font(.title3).foregroundStyle(.white)
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.75))
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack {
                Text("\(p.currentSlide + 1) / \(p.slides.count)").monospacedDigit().foregroundStyle(.white.opacity(0.7))
                Button { showNotes.toggle() } label: { Image(systemName: showNotes ? "text.bubble.fill" : "text.bubble") }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
            }
            .font(.title2).padding()
            .tint(.white)
        }
        .statusBarHidden()
    }
}

private struct StudioSettings: View {
    @Environment(StudioModel.self) private var studio
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        @Bindable var studio = studio
        NavigationStack {
            Form {
                Picker("AI", selection: $studio.provider) {
                    ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                if let reason = studio.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                switch studio.provider {
                case .appleOnDevice:
                    Text("Runs on this iPad (Apple Intelligence on M1 or later). No key, no internet, nothing leaves the device.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .anthropic:
                    TextField("Model", text: Binding(get: { studio.model }, set: { studio.models[.anthropic] = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if studio.hasAnthropicKey {
                        LabeledContent("API key") { Button("Remove", role: .destructive) { studio.saveAnthropicKey("") } }
                    } else {
                        SecureField("Anthropic API key", text: $key)
                        Button("Save key in Keychain") { studio.saveAnthropicKey(key); key = "" }.disabled(key.isEmpty)
                    }
                    Text("Your messages go to Anthropic with your own key, only when you use the assistant.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .ollama:
                    TextField("Ollama address", text: $studio.ollamaURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Model", text: Binding(get: { studio.model }, set: { studio.models[.ollama] = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Ollama running on a Mac or PC on your network, e.g. http://192.168.1.20:11434. Start it with OLLAMA_HOST=0.0.0.0.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct SamplesSheet: View {
    @Environment(StudioModel.self) private var studio
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SampleDeck.all) { deck in
                Button {
                    if let p = try? studio.workspace.createSample(deck) { studio.preview.open(p.name) }
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(deck.sector.rawValue.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.tint)
                        Text(deck.title).font(.headline)
                        Text(deck.useCase).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Sample Decks")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Hosts the shared web view (it moves between the preview and Present mode),
/// keeping it sized to its frame and telling the deck to re-fit.
struct WebPreview: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> HostView {
        let host = HostView()
        host.backgroundColor = .black
        host.attach(webView)
        return host
    }
    func updateUIView(_ host: HostView, context: Context) { host.attach(webView) }

    final class HostView: UIView {
        private weak var web: WKWebView?
        private var lastSize = CGSize.zero

        func attach(_ webView: WKWebView) {
            guard webView.superview !== self else { return }
            webView.removeFromSuperview()
            addSubview(webView)
            web = webView
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let web else { return }
            web.frame = bounds
            if bounds.size != lastSize, bounds.width > 0 {
                lastSize = bounds.size
                web.evaluateJavaScript("window.dispatchEvent(new Event('resize'))", completionHandler: nil)
            }
        }
    }
}

/// Wraps an outline for `.sheet(item:)`.
private struct EditingDeck: Identifiable {
    let id = UUID()
    let outline: DeckOutline
}

private struct MakeDeckKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// Opens the slide editor for a new deck.
    var makeDeck: @MainActor () -> Void {
        get { self[MakeDeckKey.self] }
        set { self[MakeDeckKey.self] = newValue }
    }
}
