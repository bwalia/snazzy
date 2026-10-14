import Interview
import SwiftUI

/// Edits a role kit: competencies with rubric anchors, questions, eligibility,
/// company facts and settings. Problems show as you type; approval locks a version.
struct KitEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var kit: RoleKit
    @State private var showInvite = false
    @State private var simulating: SimulatedCandidate?
    @State private var error: String?
    let onDelete: () -> Void
    let onOpenInterview: (UUID) -> Void

    init(kit: RoleKit, onDelete: @escaping () -> Void, onOpenInterview: @escaping (UUID) -> Void) {
        _kit = State(initialValue: kit)
        self.onDelete = onDelete
        self.onOpenInterview = onOpenInterview
    }

    private var saved: RoleKit? { model.interviews.kits.first { $0.id == kit.id } }
    private var dirty: Bool { saved.map { strip($0) != strip(kit) } ?? true }
    private var issues: [KitValidator.Issue] { KitValidator.check(kit) }

    /// Compares kits without bookkeeping fields.
    private func strip(_ k: RoleKit) -> RoleKit {
        var k = k
        k.updated = .distantPast
        return k
    }

    var body: some View {
        let iv = model.interviews!
        Form {
            Section {
                HStack {
                    TextField("Role title", text: $kit.title).font(.title2.bold()).textFieldStyle(.plain)
                    Spacer()
                    if let saved, saved.isApproved, !dirty {
                        Label("Approved v\(saved.version) by \(saved.approvedBy ?? "")", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Text(dirty ? "Unsaved changes" : "Draft: approve to use").foregroundStyle(.secondary)
                    }
                }
                TextField("Organisation", text: $kit.organisation)
                TextField("Language", text: $kit.language).help("For example en-GB or en-US")
                TextField("About the role (read by the interviewer)", text: $kit.summary, axis: .vertical).lineLimit(2...5)
            }

            if !kit.warnings.isEmpty {
                Section("Wording in the job description to check") {
                    ForEach(kit.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.bubble").foregroundStyle(.orange) }
                }
            }

            Section {
                ForEach($kit.competencies) { $c in
                    DisclosureGroup {
                        TextField("Name", text: $c.name)
                        TextField("What it means", text: $c.description, axis: .vertical)
                        Stepper("Weight: \(c.weight)", value: $c.weight, in: 0...100, step: 5)
                        TextField("From the job description", text: $c.source, axis: .vertical)
                        TextField("Level 1 looks like…", text: $c.anchors.level1, axis: .vertical).lineLimit(2...4)
                        TextField("Level 3 looks like…", text: $c.anchors.level3, axis: .vertical).lineLimit(2...4)
                        TextField("Level 5 looks like…", text: $c.anchors.level5, axis: .vertical).lineLimit(2...4)
                        Button("Remove Competency", role: .destructive) { kit.competencies.removeAll { $0.id == c.id } }
                    } label: {
                        HStack { Text(c.name.isEmpty ? c.id : c.name); Spacer(); Text("\(c.weight)%").foregroundStyle(.secondary) }
                    }
                }
                Button("Add Competency") {
                    let id = nextID("c", kit.competencies.map(\.id))
                    kit.competencies.append(Competency(id: id, name: "New competency"))
                }
            } header: {
                Text("Competencies and rubric")
            } footer: {
                Text("Anchors describe what a candidate says they did at each level, not personality traits.")
            }

            Section {
                ForEach($kit.questions) { $q in
                    VStack(alignment: .leading) {
                        TextField("Question", text: $q.text, axis: .vertical).lineLimit(1...4)
                        HStack {
                            Picker("Evidence for", selection: $q.competency) {
                                ForEach(kit.competencies) { Text($0.name).tag($0.id) }
                            }
                            Picker("Kind", selection: $q.kind) {
                                Text("Behavioural").tag(CoreQuestion.Kind.behavioural)
                                Text("Situational").tag(CoreQuestion.Kind.situational)
                            }
                            .fixedSize()
                            Button { move(q.id, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                            Button { move(q.id, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
                            Button(role: .destructive) { kit.questions.removeAll { $0.id == q.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("Add Question") {
                    kit.questions.append(CoreQuestion(id: nextID("q", kit.questions.map(\.id)), text: "", competency: kit.competencies.first?.id ?? ""))
                }
            } header: {
                Text("Main questions (asked word for word, in this order)")
            }

            Section {
                ForEach($kit.eligibility) { $e in
                    VStack(alignment: .leading) {
                        TextField("Question", text: $e.text, axis: .vertical)
                        HStack {
                            Picker("Answer", selection: $e.kind) {
                                Text("Yes / No").tag(EligibilityQuestion.Kind.yesNo)
                                Text("Choice").tag(EligibilityQuestion.Kind.choice)
                                Text("Text").tag(EligibilityQuestion.Kind.text)
                            }
                            .fixedSize()
                            if e.kind == .choice {
                                TextField("Options, comma separated", text: list($e.options))
                            }
                            TextField("Meets the requirement", text: list($e.accepted)).help("Answers that meet it, comma separated (shown to you, never used to reject)")
                            Button(role: .destructive) { kit.eligibility.removeAll { $0.id == e.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Eligibility Question") {
                    kit.eligibility.append(EligibilityQuestion(id: nextID("e", kit.eligibility.map(\.id)), text: "", accepted: ["Yes"]))
                }
            } header: {
                Text("Eligibility (hard requirements only)")
            } footer: {
                Text("Never salary history, and nothing about protected characteristics. Answers are shown to you as given.")
            }

            Section("What the interviewer may tell candidates") {
                TextEditor(text: $kit.companyFacts).frame(minHeight: 90).font(.body)
            }

            Section("Settings") {
                TextField("Interviewer's name", text: $kit.settings.interviewerName)
                Stepper("Length: \(kit.settings.minutes) minutes", value: $kit.settings.minutes, in: 10...60, step: 5)
                Stepper("Follow-ups per question: \(kit.settings.maxFollowUps)", value: $kit.settings.maxFollowUps, in: 0...3)
                Toggle("Candidates can pause", isOn: $kit.settings.allowPause)
                Toggle("Suggest levels (off: evidence only, e.g. for NYC Local Law 144)", isOn: $kit.settings.ratingsEnabled)
                Toggle("This role assesses written communication", isOn: $kit.settings.writtenCommunication)
                Stepper("Keep interviews \(kit.settings.retentionDays) days after the decision", value: $kit.settings.retentionDays, in: 30...730, step: 30)
                TextField("Next steps (told to every candidate)", text: $kit.settings.nextSteps, axis: .vertical)
            }

            if !issues.isEmpty {
                Section("Before approving") {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                Button("Save") { iv.save(kit); if let s = saved { kit = s } }
                    .disabled(!dirty)
                Button("Approve") {
                    do {
                        iv.save(kit)
                        if let s = saved { try iv.approve(s) }
                        if let s = saved { kit = s }
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(!KitValidator.canApprove(kit) || (saved?.isApproved == true && !dirty))
                .help("Approve this version for interviews")
                Menu {
                    ForEach(SimulatedCandidate.all) { p in Button(p.label) { simulating = p } }
                } label: { Label("Simulate", systemImage: "theatermasks") }
                .disabled(saved?.isApproved != true || dirty || !iv.isActive)
                .help("Run the kit against a simulated candidate")
                Button { showInvite = true } label: { Label("Interview a Candidate", systemImage: "person.badge.plus") }
                    .disabled(saved?.isApproved != true || dirty || !iv.isActive)
                Menu {
                    Button("Delete Role…", role: .destructive) {
                        if confirmDelete() { iv.delete(kit); onDelete() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showInvite) {
            if let saved { StartInterviewSheet(kit: saved, onCreated: onOpenInterview) }
        }
        .task(id: simulating) {
            guard let p = simulating, let saved else { return }
            do {
                let id = try await iv.simulate(kit: saved, persona: p)
                onOpenInterview(id)
            } catch {
                self.error = error.localizedDescription
            }
            simulating = nil
        }
        .overlay(alignment: .bottom) {
            if let p = simulating {
                Label("Simulating “\(p.label)”…", systemImage: "theatermasks").padding(10).background(.regularMaterial, in: Capsule()).padding()
            }
        }
    }

    private func nextID(_ prefix: String, _ ids: [String]) -> String {
        var n = ids.count + 1
        while ids.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    private func move(_ id: String, by delta: Int) {
        guard let i = kit.questions.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard kit.questions.indices.contains(j) else { return }
        kit.questions.swapAt(i, j)
    }

    private func list(_ binding: Binding<[String]>) -> Binding<String> {
        Binding(get: { binding.wrappedValue.joined(separator: ", ") },
                set: { binding.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }

    private func confirmDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete the role “\(kit.title)”?"
        alert.informativeText = "Interviews already done keep their own copy of the kit."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Invite a candidate: at this Mac (Auto Interview) or by a link on the network.
struct StartInterviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let kit: RoleKit
    let onCreated: (UUID) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var reference = ""
    @State private var channel: InterviewSession.Channel = .thisMac
    @State private var options = AutoInterview.Options()
    @State private var link: URL?
    @State private var createdID: UUID?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interview a candidate: \(kit.title)").font(.title2.bold())
            if let link {
                Text("Send this link to \(name). It works on this network until \(Calendar.current.date(byAdding: .day, value: 7, to: Date())!.formatted(date: .abbreviated, time: .omitted)), for one candidate, while Snazzy Pro is open.")
                HStack(alignment: .top, spacing: 16) {
                    if let qr = LiveController.qr(link.absoluteString) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 160, height: 160)
                    }
                    VStack(alignment: .leading) {
                        Text(link.absoluteString).textSelection(.enabled).font(.callout.monospaced())
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        }
                        Text("The link is shown only now; Snazzy Pro keeps only a fingerprint of it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack { Spacer(); Button("Done") { if let createdID { onCreated(createdID) }; dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Form {
                    TextField("Candidate's name", text: $name)
                    TextField("Email (for your follow-up)", text: $email)
                    TextField("Your reference (optional)", text: $reference)
                    Picker("Where", selection: $channel) {
                        Text("Auto Interview at this Mac").tag(InterviewSession.Channel.thisMac)
                        Text("Link on this network").tag(InterviewSession.Channel.link)
                    }
                    .pickerStyle(.radioGroup)
                    if channel == .thisMac {
                        Toggle("Show the role's deck on the Present window", isOn: $options.showDeck)
                        Toggle("Speak the questions aloud", isOn: $options.speak)
                        Toggle("Listen to spoken answers (recognised on this Mac)", isOn: $options.listen)
                        Toggle("Record the interview (slides, camera and mic) for the hiring team", isOn: $options.record)
                        if options.record {
                            Text("Candidates are told before they start. Recordings are saved to ~/Movies/Snazzy Pro and are never analysed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Text(model.interviews.isLinked ? "Results go to OpsAPI (\(model.interviews.opsapiWorkspace ?? "linked")) when ready." : "Results are saved as a .snazzy_interview file when ready.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button(channel == .thisMac ? "Start" : "Make Link") { Task { await create() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let iv = model.interviews!
            let (session, url) = try await iv.createInterview(kit: kit, candidate: Candidate(name: name, email: email, reference: reference), channel: channel)
            createdID = session.id
            if channel == .link {
                link = url
            } else {
                await iv.auto.prepare(session.id, options: options)
                if options.record { var s = session; s.log("will_record", by: iv.reviewer); iv.save(session: s) }
                onCreated(session.id)
                dismiss()
                openWindow(id: "candidate-interview")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
