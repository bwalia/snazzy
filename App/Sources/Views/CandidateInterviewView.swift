import Interview
import SwiftUI

/// What the candidate sees at this Mac during an Auto Interview: the notice and
/// adjustments, then the conversation with spoken or typed answers, then thanks
/// and the optional self-ID questions. Nothing about evidence or flags.
struct CandidateInterviewView: View {
    @Environment(AppModel.self) private var model
    @State private var adjustments: Set<String> = []
    @State private var other = ""
    @State private var typed = ""
    @State private var typing = false
    @State private var selfID: [String: String] = [:]
    @State private var selfIDDone = false
    @State private var bigText = false

    var body: some View {
        let iv = model.interviews!
        Group {
            if let id = iv.auto.sessionID, let s = iv.session(id) {
                switch s.state {
                case .invited: notice(s, id: id)
                case .inProgress, .paused: interview(s, id: id)
                default: finished(s, id: id)
                }
            } else {
                ContentUnavailableView("No interview at this Mac",
                                       systemImage: "person.2.wave.2",
                                       description: Text("Start one from a role in the Interviews window (Interview a Candidate › Auto Interview at this Mac)."))
            }
        }
        .font(bigText ? .title3 : .body)
        .frame(minWidth: 640, minHeight: 520)
    }

    // MARK: Before starting

    private func notice(_ s: InterviewSession, id: UUID) -> some View {
        let iv = model.interviews!
        let text = InterviewPrompts.notice(for: s.kit, provider: iv.providerName) + recordingNotice(s)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(s.kit.title).font(.largeTitle.bold())
                if !s.kit.organisation.isEmpty { Text(s.kit.organisation).foregroundStyle(.secondary) }
                Text(text).textSelection(.enabled).padding().background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                GroupBox("Adjustments (optional)") {
                    VStack(alignment: .leading) {
                        ForEach(s.kit.settings.allowedAdjustments, id: \.self) { a in
                            Toggle(a, isOn: Binding(get: { adjustments.contains(a) }, set: { if $0 { adjustments.insert(a) } else { adjustments.remove(a) } }))
                        }
                        TextField("Anything else?", text: $other)
                        Toggle("Larger text", isOn: $bigText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let p = iv.auto.problem { Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Button("I understand. Start the interview") {
                        var list = Array(adjustments).sorted()
                        if !other.trimmingCharacters(in: .whitespaces).isEmpty { list.append(other) }
                        if list.contains("text instead of voice") { iv.auto.useTyping() }
                        iv.start(id, noticeHash: InterviewPrompts.hash(text), adjustments: list)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("I'd prefer to speak to a person") { iv.requestPerson(id) }.controlSize(.large)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func recordingNotice(_ s: InterviewSession) -> String {
        s.audit.contains { $0.action == "will_record" }
            ? "\n\nRecording: this interview is recorded (the slides, camera and microphone) so the hiring team can watch it. The recording is not analysed by AI."
            : ""
    }

    // MARK: The interview

    private func interview(_ s: InterviewSession, id: UUID) -> some View {
        let iv = model.interviews!
        let auto = iv.auto!
        let engine = iv.engine(id)
        let question = s.turns.last { $0.role == .interviewer }?.text ?? ""
        return VStack(spacing: 0) {
            HStack {
                Text(s.kit.title).font(.headline)
                Spacer()
                if let e = engine {
                    ProgressView(value: e.progress).frame(width: 140)
                    Text("\(Int(e.secondsLeft / 60)) min left").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(s.turns.filter { $0.role != .system }) { t in
                            Text(t.text)
                                .padding(10)
                                .frame(maxWidth: 560, alignment: .leading)
                                .background(t.role == .candidate ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                .frame(maxWidth: .infinity, alignment: t.role == .candidate ? .trailing : .leading)
                                .id(t.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: s.turns.count) { _, _ in withAnimation { proxy.scrollTo(s.turns.last?.id, anchor: .bottom) } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if s.state == .paused {
                    HStack {
                        Text("Paused. Your time isn't running.")
                        Button("Carry On") { iv.send(.resume, to: id) }.buttonStyle(.borderedProminent)
                    }
                } else if iv.busy.contains(id) {
                    HStack { ProgressView().controlSize(.small); Text("\(s.kit.settings.interviewerName) is reading your answer…").foregroundStyle(.secondary) }
                } else if let choices = engine?.currentChoices {
                    HStack {
                        Text("Your answer:")
                        ForEach(choices, id: \.self) { c in Button(c) { iv.send(.answer(c, input: .typed), to: id) }.controlSize(.large) }
                        if auto.phase == .listening { Label("Or say it", systemImage: "mic.fill").foregroundStyle(.red) }
                    }
                } else if auto.options.listen && !typing {
                    HStack(alignment: .top) {
                        Image(systemName: auto.phase == .listening ? "mic.fill" : auto.phase == .speaking ? "speaker.wave.2.fill" : "ellipsis")
                            .font(.title2).foregroundStyle(auto.phase == .listening ? .red : .secondary)
                        VStack(alignment: .leading) {
                            Text(auto.phase == .speaking ? "Listen to the question…" : auto.phase == .listening ? "Listening. Take your time." : " ")
                                .foregroundStyle(.secondary)
                            Text(auto.partial.isEmpty ? " " : auto.partial).italic()
                        }
                        Spacer()
                        Button("I've Finished Answering") { auto.finishAnswer() }
                            .buttonStyle(.borderedProminent).disabled(auto.phase != .listening)
                        Button("Type Instead") { typing = true; auto.useTyping() }
                    }
                } else {
                    TextEditor(text: $typed).frame(height: 110).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    HStack {
                        Spacer()
                        Button("Send Answer") {
                            let text = typed
                            typed = ""
                            iv.send(.answer(text, input: .typed), to: id)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack {
                    Button("Repeat the Question") { iv.send(.repeatQuestion, to: id) }
                    Button("Rephrase It") { iv.send(.rephraseQuestion, to: id) }
                    if s.kit.settings.allowPause, s.state != .paused { Button("Pause") { iv.send(.pause, to: id) } }
                    Spacer()
                    Button("Speak to a Person Instead") { iv.send(.askForPerson, to: id) }
                }
                .disabled(iv.busy.contains(id))
                if let p = auto.problem { Label(p, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            .padding()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Answer: \(question)")
        }
    }

    // MARK: Afterwards

    private func finished(_ s: InterviewSession, id: UUID) -> some View {
        let iv = model.interviews!
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Thank you").font(.largeTitle.bold())
                Text(s.turns.last { $0.role == .interviewer }?.text ?? "Your interview is complete.")
                if s.state == .humanRequested {
                    Text("We've told the hiring team you'd like to speak to a person. This won't count against you.")
                }
                if (s.state == .completed || s.state == .humanRequested) && !selfIDDone {
                    GroupBox("Optional: help us check our process is fair") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("These questions are voluntary. Your answers are stored separately from your interview, are never seen by the AI or by the people deciding, and are only reported in groups of 10 or more.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(SelfID.questions, id: \.id) { q in
                                Picker(q.label, selection: Binding(get: { selfID[q.id] ?? "" }, set: { selfID[q.id] = $0 })) {
                                    Text("Choose…").tag("")
                                    ForEach(q.options, id: \.self) { Text($0).tag($0) }
                                }
                                .frame(maxWidth: 460)
                            }
                            HStack {
                                Button("Send Answers") { iv.saveSelfID(id, answers: selfID.filter { !$0.value.isEmpty }); selfIDDone = true }
                                    .buttonStyle(.borderedProminent)
                                Button("Skip") { selfIDDone = true }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("You can step away from the computer now.").foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}
