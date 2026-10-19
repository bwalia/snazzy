import Interview
import SwiftUI

/// An interview by invite link, on the candidate's own Mac: paste or open the
/// link, read the notice, then answer by voice or typing. OpsAPI runs the
/// interview; nothing about evidence or ratings is shown here.
struct JoinInterviewView: View {
    @Environment(AppModel.self) private var model
    @State private var adjustments: Set<String> = []
    @State private var other = ""
    @State private var typed = ""
    @State private var bigText = false
    @State private var selfID: [String: String] = [:]
    @State private var selfIDDone = false

    var body: some View {
        let join = model.interviews.join!
        Group {
            switch join.stage {
            case .idle, .failed: paste(join)
            case .loading: busy("Opening your interview…", nil)
            case .downloading(let f): busy("Downloading the interview pack…", f)
            case .offline(let id): offline(id)
            case .ready:
                if let v = join.view {
                    if v.state == "invited" { notice(join, v) } else if v.isFinished { finished(join, v) } else { interview(join, v) }
                }
            }
        }
        .font(bigText ? .title3 : .body)
        .frame(minWidth: 640, minHeight: 520)
    }

    // MARK: The link

    private func paste(_ join: JoinInterview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join an Interview").font(.largeTitle.bold())
            Text("Paste the link from your invitation. No account or passcode: the link is your invitation, and it works on one Mac.")
                .foregroundStyle(.secondary)
            TextField("https://…/i/…", text: Binding(get: { join.linkText }, set: { join.linkText = $0 }))
                .textFieldStyle(.roundedBorder).onSubmit { open(join) }
            Button("Open the Interview") { open(join) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(join.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
            if case .failed(let why) = join.stage { Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        .padding(28)
        .frame(maxWidth: 680, alignment: .leading)
    }

    /// An offline interview runs in the Interview window; this says where it is and what happens to the answers.
    private func offline(_ id: UUID) -> some View {
        let iv = model.interviews!
        let s = iv.session(id)
        return VStack(alignment: .leading, spacing: 14) {
            Text(s?.kit.title ?? "Your interview").font(.largeTitle.bold())
            Text("This interview runs on this Mac, so you can take it without an internet connection. Your answers stay here until the end, then go to the hiring team.")
            if let s, s.isFinished, let offline = s.offline {
                OfflineResultStatus(id: id, offline: offline)
            } else {
                Button("Open the Interview Window") { iv.candidateWindowRequest += 1 }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: 680, alignment: .leading)
    }

    private func open(_ join: JoinInterview) {
        let text = join.linkText
        Task { await join.join(text) }
    }

    private func busy(_ text: String, _ fraction: Double?) -> some View {
        VStack(spacing: 12) {
            if let fraction { ProgressView(value: fraction).frame(width: 320) } else { ProgressView() }
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Before starting

    private func notice(_ join: JoinInterview, _ v: CandidateView) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(v.roleTitle).font(.largeTitle.bold())
                if let org = v.organisation, !org.isEmpty { Text(org).foregroundStyle(.secondary) }
                Text(v.notice).textSelection(.enabled).padding().background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                if join.hasIntro {
                    Button { join.showIntro() } label: { Label("Watch the Introduction", systemImage: "play.rectangle") }
                }
                GroupBox("How you'd like to answer") {
                    VStack(alignment: .leading) {
                        Toggle("Read the questions aloud", isOn: Binding(get: { join.speak }, set: { join.speak = $0 }))
                        Toggle("Answer by speaking (heard on this Mac only)", isOn: Binding(get: { join.listen }, set: { join.listen = $0 }))
                        Toggle("Larger text", isOn: $bigText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let allowed = v.allowedAdjustments, !allowed.isEmpty {
                    GroupBox("Adjustments (optional)") {
                        VStack(alignment: .leading) {
                            ForEach(allowed, id: \.self) { a in
                                Toggle(a, isOn: Binding(get: { adjustments.contains(a) }, set: { if $0 { adjustments.insert(a) } else { adjustments.remove(a) } }))
                            }
                            TextField("Anything else?", text: $other)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let p = join.problem { Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Button("I understand. Start the interview") {
                        var list = Array(adjustments).sorted()
                        if !other.trimmingCharacters(in: .whitespaces).isEmpty { list.append(other) }
                        Task { await join.start(adjustments: list) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(join.busy)
                    Button("I'd prefer to speak to a person") { Task { await join.event("person") } }.controlSize(.large)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    // MARK: The interview

    private func interview(_ join: JoinInterview, _ v: CandidateView) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(v.roleTitle).font(.headline)
                Spacer()
                if let p = v.progress { ProgressView(value: p).frame(width: 140) }
                if let left = v.secondsLeft {
                    Text("\(left / 60):\(String(format: "%02d", left % 60)) left").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(v.turns) { t in
                            Text(t.text)
                                .padding(10)
                                .frame(maxWidth: 560, alignment: .leading)
                                .background(t.role == "candidate" ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: t.role == "candidate" ? .trailing : .leading)
                                .id(t.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: v.turns.count) { _, _ in withAnimation { proxy.scrollTo(v.turns.last?.id, anchor: .bottom) } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if v.state == "paused" {
                    HStack {
                        Text("Paused. Your time isn't running.")
                        Button("Carry On") { Task { await join.event("resume") } }.buttonStyle(.borderedProminent)
                    }
                } else if join.busy {
                    HStack { ProgressView().controlSize(.small); Text("\(v.interviewerName ?? "The interviewer") is reading your answer…").foregroundStyle(.secondary) }
                } else if let choices = v.choices, !choices.isEmpty {
                    HStack {
                        Text("Your answer:")
                        ForEach(choices, id: \.self) { c in Button(c) { Task { await join.answer(c) } }.controlSize(.large) }
                        if join.phase == .listening { Label("Or say it", systemImage: "mic.fill").foregroundStyle(.red) }
                    }
                } else if join.listen {
                    HStack(alignment: .top) {
                        Image(systemName: join.phase == .listening ? "mic.fill" : join.phase == .speaking ? "speaker.wave.2.fill" : "ellipsis")
                            .font(.title2).foregroundStyle(join.phase == .listening ? .red : .secondary)
                        VStack(alignment: .leading) {
                            Text(join.phase == .speaking ? "Listen to the question…" : join.phase == .listening ? "Listening. Take your time." : " ")
                                .foregroundStyle(.secondary)
                            Text(join.partial.isEmpty ? " " : join.partial).italic()
                        }
                        Spacer()
                        Button("I've Finished Answering") { join.finishAnswer() }
                            .buttonStyle(.borderedProminent).disabled(join.phase != .listening)
                        Button("Type Instead") { join.useTyping() }
                    }
                } else {
                    TextEditor(text: $typed).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    HStack {
                        Spacer()
                        Button("Send Answer") {
                            let text = typed
                            typed = ""
                            Task { await join.answer(text) }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack {
                    Button("Repeat the Question") { Task { await join.event("repeat") } }
                    Button("Rephrase It") { Task { await join.event("rephrase") } }
                    if v.allowPause == true, v.state != "paused" { Button("Pause") { Task { await join.event("pause") } } }
                    Spacer()
                    Button("Speak to a Person Instead") { Task { await join.event("person") } }
                }
                .disabled(join.busy)
                if let p = join.problem { Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            .padding()
        }
    }

    // MARK: Afterwards

    private func finished(_ join: JoinInterview, _ v: CandidateView) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Thank you").font(.largeTitle.bold())
                Text(v.turns.last { $0.role == "interviewer" }?.text ?? "Your interview is complete.")
                if let questions = v.selfId, !questions.isEmpty, !selfIDDone {
                    GroupBox("Optional: help us check our process is fair") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("These questions are voluntary. Your answers are stored separately from your interview, are never seen by the AI or by the people deciding, and are only reported in groups of 10 or more.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(questions, id: \.id) { q in
                                Picker(q.label, selection: Binding(get: { selfID[q.id] ?? "" }, set: { selfID[q.id] = $0 })) {
                                    Text("Choose…").tag("")
                                    ForEach(q.options, id: \.self) { Text($0).tag($0) }
                                }
                                .frame(maxWidth: 460)
                            }
                            HStack {
                                Button("Send Answers") {
                                    let answers = selfID.filter { !$0.value.isEmpty }
                                    selfIDDone = true
                                    Task { await join.sendSelfID(answers) }
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Skip") { selfIDDone = true }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("You can close this window now.").foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}
