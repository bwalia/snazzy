import Interview
import SwiftUI
import UniformTypeIdentifiers

/// One interview: evidence per competency (quotes linked to the transcript), the
/// AI's suggested levels clearly marked as suggestions, flags, eligibility answers,
/// and the reviewer's own levels and decision.
struct InterviewDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let id: UUID
    let onDelete: () -> Void

    @State private var levels: [String: Int] = [:]
    @State private var note = ""
    @State private var reason = InterviewDetailView.reasons[0]
    @State private var highlight: String?
    @State private var loaded = false
    @State private var info: String?

    static let reasons = [
        "Evidence meets the role's needs", "Evidence partly meets the role's needs", "Not enough evidence yet",
        "Evidence doesn't meet the role's needs", "Doesn't meet an eligibility requirement", "Candidate withdrew", "Other (see note)",
    ]

    var body: some View {
        let iv = model.interviews!
        if let s = iv.session(id) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(s)
                        if !s.flags.isEmpty || !s.forwardedQuestions.isEmpty { flags(s) }
                        if !s.kit.eligibility.isEmpty, !s.eligibilityAnswers.isEmpty { eligibility(s) }
                        evidence(s, proxy: proxy)
                        decision(s)
                        transcript(s)
                        audit(s)
                    }
                    .padding(20)
                    .frame(maxWidth: 900, alignment: .leading)
                }
            }
            .toolbar { toolbar(s) }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                levels = s.review?.levels ?? [:]
                note = s.review?.note ?? ""
                if let r = s.review?.reason, !r.isEmpty { reason = r }
            }
        }
    }

    // MARK: Sections

    private func header(_ s: InterviewSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.candidate.name.isEmpty ? "Candidate" : s.candidate.name).font(.largeTitle.bold())
            Text("\(s.kit.title) · kit v\(s.kit.version) · \(InterviewGroup.status(s))").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if !s.candidate.email.isEmpty { Label(s.candidate.email, systemImage: "envelope") }
                if !s.candidate.reference.isEmpty { Label(s.candidate.reference, systemImage: "number") }
                if let start = s.startedAt { Label(start.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar") }
                if s.startedAt != nil { Label("\(Int(s.elapsed() / 60)) min", systemImage: "clock") }
                Label(s.channel == .link ? "Link" : s.channel == .hosted ? "OpsAPI" : "At this Mac", systemImage: "desktopcomputer")
            }
            .font(.callout).foregroundStyle(.secondary)
            if s.state == .invited || s.state == .inProgress || s.state == .paused {
                HStack {
                    if s.channel == .thisMac {
                        Button("Open the Candidate Window") { openWindow(id: "candidate-interview") }
                    }
                    if s.state == .invited, let expires = s.linkExpires {
                        Text("Link expires \(expires.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let movie = s.recordingMovie, FileManager.default.fileExists(atPath: movie.path) {
                HStack {
                    Button { NSWorkspace.shared.open(movie) } label: { Label("Watch Recording", systemImage: "play.rectangle") }
                    Text("Recorded with the candidate's consent. It isn't analysed by AI; watch it yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let c = s.camera {
                Text(c.withdrawnAt != nil ? "The candidate turned their camera off; the recording was deleted."
                     : c.agreed ? "Camera on (consent \(c.at.formatted(date: .abbreviated, time: .shortened)))." : "The candidate chose to keep their camera off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let info { Text(info).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func flags(_ s: InterviewSession) -> some View {
        GroupBox("Needs your attention") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(s.flags.enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .top) {
                        Image(systemName: icon(f.kind)).foregroundStyle(color(f.kind)).frame(width: 18)
                        VStack(alignment: .leading) {
                            Text(f.label).bold()
                            // Protected topics: only the topic, never the details.
                            if !f.detail.isEmpty { Text(f.detail).font(.callout).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let t = f.turn { Button("Show") { highlight = t }.buttonStyle(.link) }
                    }
                }
                ForEach(s.forwardedQuestions, id: \.self) { q in
                    Label("Asked: “\(q.count > 240 ? q.prefix(240) + "…" : q)”: passed to you.", systemImage: "questionmark.bubble").foregroundStyle(.blue)
                        .help(q)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func eligibility(_ s: InterviewSession) -> some View {
        GroupBox("Eligibility answers (as given)") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(s.kit.eligibility) { q in
                    if let a = s.eligibilityAnswers[q.id] {
                        HStack(alignment: .top) {
                            Text(q.text).frame(maxWidth: .infinity, alignment: .leading)
                            Text(a).bold()
                            switch q.meets(a) {
                            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Meets the requirement")
                            case false?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Doesn't meet the stated requirement: check with the candidate")
                            case nil: EmptyView()
                            }
                        }
                    }
                }
            }
        }
    }

    private func evidence(_ s: InterviewSession, proxy: ScrollViewProxy) -> some View {
        let iv = model.interviews!
        return GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let e = s.evaluation {
                    Text("AI suggestions are advice. The levels you set below are the ones that count. Model: \(e.model).")
                        .font(.caption).foregroundStyle(.secondary)
                    if e.droppedQuotes > 0 {
                        Label("\(e.droppedQuotes) quote(s) the AI gave weren't in the transcript and were removed.", systemImage: "scissors")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !e.injection.isEmpty {
                        Label("The candidate's text tried to instruct the AI; it was ignored.", systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !e.notesForReviewer.isEmpty { Text(e.notesForReviewer).font(.callout) }
                    ForEach(s.kit.competencies) { c in competency(c, result: e.result(c.id), s: s, proxy: proxy) }
                } else if iv.evaluating.contains(id) {
                    HStack { ProgressView().controlSize(.small); Text("The AI is gathering the evidence…") }
                } else if s.isFinished, !s.candidateTurns.isEmpty {
                    HStack {
                        Text("No evidence summary yet.")
                        Button("Gather Evidence") { Task { await iv.evaluate(id) } }
                    }
                    ForEach(s.kit.competencies) { c in competency(c, result: nil, s: s, proxy: proxy) }
                } else {
                    Text("The evidence summary appears when the interview ends.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Evidence by competency")
        }
    }

    private func competency(_ c: Competency, result: CompetencyResult?, s: InterviewSession, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(c.name).font(.headline)
                Text("\(c.weight)%").foregroundStyle(.secondary)
                Spacer()
                if let r = result {
                    if s.kit.settings.ratingsEnabled {
                        Text(r.level.map { "AI suggestion: \($0)" } ?? "AI: not enough evidence")
                            .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if !r.agreed {
                        Label("Low agreement (\(r.level.map(String.init) ?? "–") vs \(r.secondLevel.map(String.init) ?? "–"))", systemImage: "arrow.left.arrow.right")
                            .font(.caption).foregroundStyle(.orange).help("Two independent AI runs disagreed. Read the evidence closely.")
                    }
                }
            }
            if let r = result {
                if r.evidence.isEmpty {
                    Text("No evidence in the answers.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(r.evidence.enumerated()), id: \.offset) { _, q in
                    Button {
                        highlight = q.turn
                        withAnimation { proxy.scrollTo(q.turn, anchor: .center) }
                    } label: {
                        Text("“\(q.quote)”").italic().multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help("Show in the transcript")
                }
                if !r.reason.isEmpty { Text(r.reason).font(.callout) }
                if !r.probeNext.isEmpty { Label("Next round, ask: \(r.probeNext)", systemImage: "arrow.turn.down.right").font(.callout).foregroundStyle(.secondary) }
            }
            DisclosureGroup("Rubric") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("1: \(c.anchors.level1)")
                    Text("3: \(c.anchors.level3)")
                    Text("5: \(c.anchors.level5)")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Your level", selection: Binding(get: { levels[c.id] ?? -1 }, set: { levels[c.id] = $0 < 0 ? nil : $0 })) {
                Text("Not set").tag(-1)
                Text("Not enough evidence").tag(0)
                ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
            }
            .frame(maxWidth: 320)
            Divider()
        }
    }

    private func decision(_ s: InterviewSession) -> some View {
        let iv = model.interviews!
        return GroupBox("Your decision") {
            VStack(alignment: .leading, spacing: 8) {
                if let r = s.review, let d = r.decision {
                    Label("\(d.label) by \(r.reviewer), \(r.at.formatted(date: .abbreviated, time: .shortened)): \(r.reason)", systemImage: "person.fill.checkmark")
                    if let n = r.candidateNotifiedAt {
                        Text("Candidate told \(n.formatted(date: .abbreviated, time: .shortened)).").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Reason", selection: $reason) { ForEach(Self.reasons, id: \.self) { Text($0).tag($0) } }
                    .frame(maxWidth: 480)
                TextField("Note (kept with the decision)", text: $note, axis: .vertical).lineLimit(2...5)
                HStack {
                    Button("Save Notes") { iv.saveReview(id, levels: levels, note: note) }
                    Spacer()
                    Button("Hold") { iv.decide(id, .hold, reason: reason, note: note, levels: levels) }
                    Button("Decline…") {
                        if confirmDecline(s) { iv.decide(id, .decline, reason: reason, note: note, levels: levels) }
                    }
                    Button("Advance") { iv.decide(id, .advance, reason: reason, note: note, levels: levels) }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(!s.isFinished)
                if s.review?.decision != nil, !s.candidate.email.isEmpty {
                    Button("Email the Candidate…") { iv.notifyCandidate(id) }
                        .help("Opens a message in your mail app; you check and send it.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transcript(_ s: InterviewSession) -> some View {
        GroupBox("Transcript") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(s.turns.filter { $0.role != .system }) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(t.role == .candidate ? (s.candidate.name.isEmpty ? "Candidate" : s.candidate.name) : s.kit.settings.interviewerName)
                                .font(.caption.bold())
                            Text(t.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                            if t.input == .spoken { Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary) }
                            if t.input == .pasted { Image(systemName: "doc.on.clipboard").font(.caption2).foregroundStyle(.secondary).help("Pasted (information only)") }
                        }
                        Text(t.text).textSelection(.enabled)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlight == t.id ? Color.yellow.opacity(0.25) : (t.role == .candidate ? Color.accentColor.opacity(0.08) : .clear),
                                in: RoundedRectangle(cornerRadius: 8))
                    .id(t.id)
                }
            }
        }
    }

    private func audit(_ s: InterviewSession) -> some View {
        DisclosureGroup("Audit log (\(s.audit.count))") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(s.audit.enumerated()), id: \.offset) { _, a in
                    Text("\(a.at.formatted(date: .abbreviated, time: .standard)) · \(a.who) · \(a.action)\(a.detail.isEmpty ? "" : ": \(a.detail)")")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                ForEach(s.models.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                    Text("\(k): \(v)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ s: InterviewSession) -> some ToolbarContent {
        let iv = model.interviews!
        ToolbarItemGroup {
            if iv.isLinked {
                Button {
                    Task {
                        do {
                            let url = try await iv.sendToOpsAPI(id)
                            info = "Sent to OpsAPI." + (url.map { " \($0)" } ?? "")
                        } catch { info = error.localizedDescription }
                    }
                } label: { Label("Send to OpsAPI", systemImage: "icloud.and.arrow.up") }
                .disabled(!s.isFinished)
            }
            Button {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = InterviewFile.fileName(for: s)
                panel.allowedContentTypes = [UTType(filenameExtension: InterviewFile.fileExtension) ?? .json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try InterviewFile.encode(s, app: iv.appVersion).write(to: url, options: .atomic)
                    info = "Saved \(url.lastPathComponent)."
                } catch { info = error.localizedDescription }
            } label: { Label("Save Results File", systemImage: "square.and.arrow.down") }
            .help("A .snazzy_interview file, for OpsAPI or another Mac")
            Menu {
                Button("Gather Evidence Again") { Task { await iv.evaluate(id) } }.disabled(!s.isFinished)
                Button("Show Results Folder") {
                    try? FileManager.default.createDirectory(at: InterviewController.resultsFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(InterviewController.resultsFolder)
                }
                Divider()
                Button("Delete Interview…", role: .destructive) {
                    if confirmDelete(s) { iv.delete(s); onDelete() }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    // MARK: Helpers

    private func icon(_ k: Flag.Kind) -> String {
        switch k {
        case .humanRequested: "person.wave.2"
        case .adjustment: "figure.roll"
        case .distress: "heart"
        case .protectedInfoVolunteered: "eye.slash"
        case .injectionAttempt: "exclamationmark.shield"
        case .technical: "wrench.and.screwdriver"
        case .timeUp: "clock.badge.exclamationmark"
        case .pasted: "doc.on.clipboard"
        default: "flag"
        }
    }

    private func color(_ k: Flag.Kind) -> Color {
        switch k {
        case .humanRequested, .adjustment, .distress: .blue
        case .injectionAttempt, .technical, .timeUp: .orange
        default: .secondary
        }
    }

    private func confirmDecline(_ s: InterviewSession) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Decline \(s.candidate.name.isEmpty ? "this candidate" : s.candidate.name)?"
        alert.informativeText = "This records your decision with the reason “\(reason)”. Nothing is sent to the candidate until you email them yourself."
        alert.addButton(withTitle: "Decline")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDelete(_ s: InterviewSession) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete this interview?"
        alert.informativeText = "The transcript, evidence and decision are deleted from this Mac. Files you saved and copies sent to OpsAPI aren't affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
