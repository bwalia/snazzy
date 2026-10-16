import AppKit
import Interview
import SwiftUI
import UniformTypeIdentifiers

/// What the user has done in each prep kit (topics studied, exercises done),
/// kept on this Mac.
struct PrepProgress: Codable, Equatable {
    var topics: Set<String> = []
    var exercises: Set<String> = []

    static let key = "SnazzyPro.prepProgress.v1"

    static func load() -> [String: PrepProgress] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: PrepProgress].self, from: data) else { return [:] }
        return all
    }

    static func save(_ all: [String: PrepProgress]) {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Interview Prep (free): pick a role, study its topics, do the hands-on
/// exercises (recorded as walkthroughs), and practise the interview with your own
/// AI model, with coaching afterwards.
struct PrepView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var progress = PrepProgress.load()
    @State private var speak = true
    @State private var listen = false
    @State private var error: String?
    @State private var notice: String?
    @State private var importing = false
    @State private var linkSheet = false
    @State private var link = ""
    @State private var dropping = false

    private var kits: [PrepKit] { model.interviews.prepKits }

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Prep kits (free)") {
                    ForEach(kits) { kit in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kit.role)
                                ProgressView(value: completion(kit)).frame(maxWidth: 140)
                            }
                            Spacer()
                            if isReady(kit) { Image(systemName: "rosette").foregroundStyle(.yellow).help("Interview ready") }
                        }
                        .tag(kit.slug)
                        .contextMenu {
                            Button("Share Prep Pack…") { share([kit]) }
                            if model.interviews.addedPrepSlugs.contains(kit.slug) {
                                Button("Remove", role: .destructive) { model.interviews.removePrepKit(kit.slug) }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Menu {
                        Button("Open a Prep Pack File…") { importing = true }
                        Button("Add from a Link…") { link = ""; linkSheet = true }
                    } label: { Label("Add Prep Pack", systemImage: "plus") }
                    .menuStyle(.borderlessButton)
                    Text("Or drop a .snazzyprep or .zip file here.").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let kit = kits.first(where: { $0.slug == selected }) {
                detail(kit).id(kit.slug)
            } else {
                ContentUnavailableView {
                    Label("Interview Prep", systemImage: "graduationcap")
                } description: {
                    Text("Free prep kits for technical roles: study the topics, learn by doing with hands-on exercises you record as walkthroughs, and practise the interview with your own AI model. Pick a role to start.")
                }
            }
        }
        .onAppear { if selected == nil { selected = kits.first?.slug } }
        .onChange(of: progress) { _, p in PrepProgress.save(p) }
        .toolbar {
            ToolbarItem {
                Button { share(kits.filter { $0.slug == selected }) } label: { Label("Share Prep Pack", systemImage: "square.and.arrow.up") }
                    .disabled(selected == nil)
                    .help("Send this prep kit as a .snazzyprep file (a plain zip, no passcode): AirDrop, Mail, Messages…")
            }
            ToolbarItem {
                Button { share(kits) } label: { Label("Share All", systemImage: "square.and.arrow.up.on.square") }
                    .help("All prep kits in one .snazzyprep file")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.snazzyPrep, .zip, .json], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { for url in urls { add { try model.interviews.addPrepPack(url) } } }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add { try model.interviews.addPrepPack(url) } }
                }
            }
            return true
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(4) } }
        .overlay(alignment: .bottom) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill").padding(10).background(.regularMaterial, in: Capsule()).padding()
                    .task { try? await Task.sleep(for: .seconds(4)); self.notice = nil }
            }
        }
        .sheet(isPresented: $linkSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a Prep Pack from a Link").font(.headline)
                TextField("https://…/cdn-engineer.snazzyprep", text: $link).textFieldStyle(.roundedBorder).frame(width: 420)
                HStack {
                    Spacer()
                    Button("Cancel") { linkSheet = false }
                    Button("Add") {
                        linkSheet = false
                        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
                        Task {
                            do { added(try await model.interviews.addPrepPack(from: url)) } catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    // MARK: Detail

    private func detail(_ kit: PrepKit) -> some View {
        let practice = practices(kit)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(kit.role).font(.largeTitle.bold())
                        if isReady(kit) {
                            Label("Interview ready", systemImage: "rosette").font(.headline).foregroundStyle(.yellow)
                                .padding(.horizontal, 10).padding(.vertical, 4).background(.yellow.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(kit.summary).foregroundStyle(.secondary)
                    ProgressView(value: completion(kit)) {
                        Text("\(Int(completion(kit) * 100))% ready").font(.caption)
                    }
                    .frame(maxWidth: 420)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(kit.topics) { topic in
                            Toggle(isOn: tick(kit, \.topics, topic.title)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(topic.title).font(.headline)
                                    Text(topic.why).font(.callout).foregroundStyle(.secondary)
                                    Text(topic.points.map { "• \($0)" }.joined(separator: "\n")).font(.callout)
                                    HStack { ForEach(topic.links, id: \.url) { l in if let u = URL(string: l.url) { Link(l.title, destination: u).font(.caption) } } }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        Button { open { try model.interviews.openStudyDeck(kit) } } label: { Label("Open as a Study Deck", systemImage: "rectangle.on.rectangle") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("1. Study", systemImage: "book") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Do these in your own code editor, then record a short screen-and-camera walkthrough with Snazzy Pro. Explaining your work out loud is the best interview practice, and the video is yours to share.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(kit.exercises) { ex in
                            Toggle(isOn: tick(kit, \.exercises, ex.title)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ex.title).font(.headline)
                                    Text(ex.goal).font(.callout).foregroundStyle(.secondary)
                                    ForEach(Array(ex.steps.enumerated()), id: \.offset) { i, step in Text("\(i + 1). \(step)").font(.callout) }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        Button { recordWalkthrough() } label: { Label("Set Up a Walkthrough Recording", systemImage: "record.circle") }
                            .help("Opens Sources & Preview: choose your screen or editor window and camera, then press Record.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("2. Learn by doing", systemImage: "hammer") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(kit.practice.questions.count) questions, the same style real interviews use. Your AI model plays the interviewer (\(model.settings.selection(for: .quickCommands).model)); afterwards you get coaching on each skill: what came across, what a strong answer covers, and what to add next time. Nothing is sent to an employer.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Toggle("Speak the questions", isOn: $speak)
                            Toggle("Answer by voice", isOn: $listen)
                        }
                        Button {
                            Task {
                                do { _ = try await model.interviews.startPractice(kit, speak: speak, listen: listen) } catch { self.error = error.localizedDescription }
                            }
                        } label: { Label("Start a Practice Interview", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        if !practice.isEmpty { progressChart(kit, practice) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("3. Practise", systemImage: "person.wave.2") }

                if let error { Text(error).foregroundStyle(.red) }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    /// Best level per skill across practices, and the latest, as bars.
    private func progressChart(_ kit: PrepKit, _ practice: [InterviewSession]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your progress (\(practice.count) practice interview\(practice.count == 1 ? "" : "s"))").font(.headline)
            ForEach(kit.practice.competencies) { c in
                let levels = practice.compactMap { $0.evaluation?.result(c.id)?.level }
                let best = levels.max() ?? 0
                HStack {
                    Text(c.name).frame(width: 220, alignment: .leading)
                    ProgressView(value: Double(best), total: 5).frame(width: 200)
                    Text(best == 0 ? "–" : "\(best)/5").monospacedDigit().foregroundStyle(best >= 3 ? .green : .orange)
                }
                .font(.callout)
            }
            if let last = practice.first(where: { $0.evaluation != nil }) {
                Button("See the Latest Coaching") {
                    Task { @MainActor in
                        await model.interviews.auto.prepare(last.id, options: AutoInterview.Options(speak: false, listen: false, showDeck: false))
                        model.interviews.candidateWindowRequest += 1
                    }
                }
            }
        }
    }

    // MARK: Progress

    private func practices(_ kit: PrepKit) -> [InterviewSession] {
        model.interviews.practiceSessions.filter { $0.kit.title == kit.practice.title }
    }

    private func completion(_ kit: PrepKit) -> Double {
        let p = progress[kit.slug] ?? PrepProgress()
        let total = Double(kit.topics.count + kit.exercises.count + 1)
        let done = Double(p.topics.count + p.exercises.count) + (practices(kit).contains { $0.evaluation != nil } ? 1 : 0)
        return min(1, done / total)
    }

    /// Everything studied and done, and a practice with every skill at 3 or more.
    private func isReady(_ kit: PrepKit) -> Bool {
        guard completion(kit) >= 1 else { return false }
        return practices(kit).contains { s in
            kit.practice.competencies.allSatisfy { (s.evaluation?.result($0.id)?.level ?? 0) >= 3 }
        }
    }

    private func tick(_ kit: PrepKit, _ path: WritableKeyPath<PrepProgress, Set<String>>, _ item: String) -> Binding<Bool> {
        Binding(get: { progress[kit.slug]?[keyPath: path].contains(item) == true },
                set: { on in
                    var p = progress[kit.slug] ?? PrepProgress()
                    if on { p[keyPath: path].insert(item) } else { p[keyPath: path].remove(item) }
                    progress[kit.slug] = p
                })
    }

    private func recordWalkthrough() {
        model.sidePanelTab = .sources
        NSApp.windows.first { $0.title == "Snazzy Pro" }?.makeKeyAndOrderFront(nil)
    }

    private func add(_ action: () throws -> [PrepKit]) {
        do { added(try action()) } catch { self.error = error.localizedDescription }
    }

    private func added(_ kits: [PrepKit]) {
        error = nil
        selected = kits.first?.slug ?? selected
        notice = "Added " + kits.map(\.role).joined(separator: ", ")
    }

    private func share(_ kits: [PrepKit]) {
        guard !kits.isEmpty else { return }
        do { FileSharing.share(try model.interviews.exportPrepPack(kits)) } catch { self.error = error.localizedDescription }
    }

    private func open(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

/// Coaching after a practice interview (shown in the candidate window).
struct CoachingView: View {
    let session: InterviewSession

    var body: some View {
        let items = Coaching.items(for: session)
        VStack(alignment: .leading, spacing: 14) {
            Text("Your coaching").font(.title2.bold())
            Text("From your own AI model, for you only. Levels compare your answers with what a strong answer at this level of role covers.")
                .font(.callout).foregroundStyle(.secondary)
            if items.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Preparing your coaching…") }
            }
            ForEach(items, id: \.competency) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.competency).font(.headline)
                        Spacer()
                        Text(item.level.map { "\($0)/5" } ?? "Not enough detail yet")
                            .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(((item.level ?? 0) >= 3 ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                    }
                    if !item.heard.isEmpty {
                        Text("What came across: " + item.heard.map { "“\($0)”" }.joined(separator: " ")).font(.callout).italic()
                    }
                    Label("A strong answer: \(item.strongAnswer)", systemImage: "star").font(.callout)
                    Label("Next time: \(item.nextTime)", systemImage: "arrow.turn.down.right").font(.callout).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

extension UTType {
    /// `.snazzyprep`: a prep pack (a plain zip of prep kits).
    static let snazzyPrep = UTType(exportedAs: "com.snazzy.pro.prep", conformingTo: .zip)
}

/// The system share menu (AirDrop, Mail, Messages…) for a file, from the key window.
@MainActor
enum FileSharing {
    static func share(_ url: URL) {
        guard let view = NSApp.keyWindow?.contentView else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: view.bounds.maxX - 120, y: view.bounds.maxY - 8, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}
