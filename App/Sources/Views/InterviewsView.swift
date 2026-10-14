import Interview
import StoreKit
import SwiftUI

/// The Interviews window: role kits, interviews, review and fairness.
struct InterviewsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Item?
    @State private var showGenerate = false
    @State private var showOpsAPI = false
    @State private var error: String?

    enum Item: Hashable {
        case kit(UUID), interview(UUID), fairness, activation
    }

    var body: some View {
        if model.interviews.interviewMode {
            InterviewModeLock()
        } else {
            content
        }
    }

    private var content: some View {
        let iv = model.interviews!
        return NavigationSplitView {
            List(selection: $selection) {
                if !iv.isActive {
                    Label("Activate Snazzy Interview", systemImage: "lock.open").tag(Item.activation)
                }
                Section("Roles") {
                    ForEach(iv.kits) { kit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kit.title).lineLimit(1)
                            Text(kit.isApproved ? "Approved · v\(kit.version)" : "Draft")
                                .font(.caption).foregroundStyle(kit.isApproved ? .green : .secondary)
                        }
                        .tag(Item.kit(kit.id))
                    }
                }
                ForEach(InterviewGroup.allCases, id: \.self) { group in
                    let items = iv.interviews.filter { group.contains($0) }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { s in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.candidate.name.isEmpty ? "Candidate" : s.candidate.name).lineLimit(1)
                                    Text("\(s.kit.title) · \(InterviewGroup.status(s))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .tag(Item.interview(s.id))
                            }
                        }
                    }
                }
                Section("Reports") {
                    Label("Fairness", systemImage: "chart.bar.xaxis").tag(Item.fairness)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("From a Job Description…") { showGenerate = true }.disabled(!iv.isActive)
                        Button("Blank Role") { selection = .kit(iv.newKit().id) }
                        Menu("Sample Roles") {
                            ForEach(InterviewController.sampleRoleNames.sorted { $0.value < $1.value }, id: \.key) { resource, title in
                                Button(title) { if let k = iv.addSample(resource) { selection = .kit(k.id) } }
                            }
                        }
                    } label: { Label("New Role", systemImage: "plus") }
                    .help("New role kit")
                }
                ToolbarItem {
                    Button { showOpsAPI = true } label: {
                        Label("OpsAPI", systemImage: iv.isLinked ? "link.circle.fill" : "link.circle")
                    }
                    .help(iv.isLinked ? "Linked to OpsAPI (\(iv.opsapiWorkspace ?? ""))" : "Link OpsAPI's interview management")
                }
            }
        } detail: {
            Group {
                switch selection {
                case .kit(let id)?:
                    if let kit = iv.kits.first(where: { $0.id == id }) {
                        KitEditorView(kit: kit, onDelete: { selection = nil }, onOpenInterview: { selection = .interview($0) })
                            .id(kit.id)
                    } else { placeholder }
                case .interview(let id)?:
                    if iv.session(id) != nil {
                        InterviewDetailView(id: id, onDelete: { selection = nil }).id(id)
                    } else { placeholder }
                case .fairness?:
                    FairnessView()
                case .activation?:
                    ActivationView()
                case nil:
                    placeholder
                }
            }
            .frame(minWidth: 560, minHeight: 480)
            .overlay {
                if let jd = iv.draftingFrom {
                    DraftingView(jobDescription: jd)
                }
            }
        }
        .sheet(isPresented: $showGenerate) {
            GenerateKitSheet { kit in selection = .kit(kit.id) }
        }
        .sheet(isPresented: $showOpsAPI) { OpsAPILinkSheet() }
        .alert("Interviews", isPresented: Binding(get: { iv.message != nil }, set: { if !$0 { iv.message = nil } })) {
            Button("OK") { iv.message = nil }
        } message: { Text(iv.message ?? "") }
        .onAppear { if !iv.isActive && iv.kits.isEmpty { selection = .activation } }
        .onChange(of: iv.focus) { _, item in if let item { selection = item } }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("Snazzy Interview", systemImage: "person.2.wave.2")
        } description: {
            Text("Create a role from a job description, approve its questions and rubric, then interview candidates at this Mac or by a link. The AI gathers evidence; you decide.")
        }
    }
}

/// How interviews are grouped in the sidebar.
enum InterviewGroup: CaseIterable {
    case needsReview, running, decided

    var title: String {
        switch self {
        case .needsReview: "To review"
        case .running: "Invited and in progress"
        case .decided: "Decided"
        }
    }

    func contains(_ s: InterviewSession) -> Bool {
        switch self {
        case .needsReview: s.isFinished && s.review?.decision == nil
        case .running: !s.isFinished
        case .decided: s.review?.decision != nil
        }
    }

    static func status(_ s: InterviewSession) -> String {
        if let d = s.review?.decision { return d.label }
        switch s.state {
        case .invited: return "Invited"
        case .inProgress: return "In progress"
        case .paused: return "Paused"
        case .completed: return s.evaluation == nil ? "Completed" : "Ready to review"
        case .humanRequested: return "Asked for a person"
        case .abandoned: return "Not finished"
        case .expired: return "Link expired"
        case .withdrawn: return "Withdrawn"
        }
    }
}

/// Paste a job description; the Planning model drafts a kit to edit and approve.
struct GenerateKitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    let onCreated: (RoleKit) -> Void

    var body: some View {
        let iv = model.interviews!
        VStack(alignment: .leading, spacing: 12) {
            Text("New role from a job description").font(.title2.bold())
            Text("Paste the job description. The AI drafts competencies, questions, rubric anchors and eligibility questions, and points out wording that could exclude people. You edit and approve everything before it's used.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Text("Uses your Planning model (\(model.settings.selection(for: .planning).model)).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    Task {
                        do {
                            let kit = try await iv.generateKit(from: text)
                            onCreated(kit)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                } label: {
                    if iv.generatingKit { ProgressView().controlSize(.small) } else { Text("Draft the Kit") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(iv.generatingKit || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

/// Subscribe to activate the module (reading and reviewing always work).
struct ActivationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.purchase) private var purchase

    var body: some View {
        let iv = model.interviews!
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Snazzy Interview").font(.largeTitle.bold())
                Text("Structured first-round interviews, run the same way for every candidate. The AI asks your approved questions, follows up on vague answers and quotes the evidence for each skill. You make every decision.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Role kits from a job description: competencies, questions, rubrics", systemImage: "doc.text.magnifyingglass")
                    Label("Interviews at this Mac or by a link on your network", systemImage: "link")
                    Label("Evidence with quotes, checked against the transcript", systemImage: "quote.opening")
                    Label("Fair by design: same questions, no face or voice analysis, protected topics hidden", systemImage: "scale.3d")
                    Label("Adjustments, and a way to ask for a person, for every candidate", systemImage: "figure.roll")
                    Label("Fairness reports and retention dates", systemImage: "chart.bar.xaxis")
                }
                if iv.isActive {
                    Label("Snazzy Interview is active.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else if let product = iv.subscriptionProduct {
                    HStack {
                        Button("Subscribe for \(product.displayPrice) a month") {
                            Task { await iv.buy { try await purchase(product) } }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Restore Purchases") { Task { await iv.restore() } }
                    }
                    Text("Interviews use your own AI model settings (Quick commands and Planning). Cancel any time in the App Store.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(iv.loadedProduct
                         ? "Subscriptions aren't available in this copy of Snazzy Pro. Get it from the Mac App Store to activate Snazzy Interview."
                         : "Loading the price…")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Link("Terms of Use", destination: ProView.termsOfUse)
                    Link("Privacy Policy", destination: ProView.privacyPolicy)
                }
                .font(.caption)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .task { if !iv.loadedProduct { await iv.loadProduct() } }
    }
}

struct FairnessView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let reports = model.interviews.fairness()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Fairness").font(.title.bold())
                Text("Advance rates by group, from candidates' voluntary self-ID answers (decided interviews only; \"hold\" isn't counted). Groups with fewer than \(Fairness.minimumGroup) people aren't shown. An impact ratio below 0.8 (the four-fifths guideline) is a sign to look closer at the kit and the decisions.")
                    .foregroundStyle(.secondary)
                ForEach(reports, id: \.question) { report in
                    GroupBox(SelfID.questions.first { $0.id == report.question }?.label ?? report.question) {
                        if report.rows.isEmpty {
                            Text("Not enough answers yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                GridRow {
                                    Text("Group").bold(); Text("Decided").bold(); Text("Advanced").bold(); Text("Rate").bold(); Text("Impact ratio").bold()
                                }
                                ForEach(report.rows, id: \.group) { row in
                                    GridRow {
                                        Text(row.group)
                                        Text("\(row.total)")
                                        Text("\(row.selected)")
                                        Text(row.rate.formatted(.percent.precision(.fractionLength(0))))
                                        Label(row.impactRatio.formatted(.number.precision(.fractionLength(2))),
                                              systemImage: row.warning ? "exclamationmark.triangle.fill" : "checkmark")
                                            .foregroundStyle(row.warning ? .orange : .primary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if report.suppressed > 0 {
                            Text("\(report.suppressed) smaller group(s) not shown.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

/// Links OpsAPI's interview management: results go there as soon as they're ready,
/// and kits made in the dashboard can be used here. Without it, results are saved
/// as .snazzy_interview files.
struct OpsAPILinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        let iv = model.interviews!
        VStack(alignment: .leading, spacing: 12) {
            Text("OpsAPI interview management").font(.title2.bold())
            if iv.isLinked {
                Label("Linked to \(iv.opsapiWorkspace ?? "OpsAPI") at \(iv.opsapiURL?.host() ?? "")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Finished interviews are sent there as soon as their evidence is ready. If sending fails, a .snazzy_interview file is saved instead.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Get Kits from OpsAPI") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do { status = "\(try await iv.fetchKitsFromOpsAPI()) approved kit(s) available." } catch { status = error.localizedDescription }
                        }
                    }
                    Button("Unlink", role: .destructive) { iv.unlinkOpsAPI() }
                }
            } else {
                Text("Without OpsAPI, results are saved as .snazzy_interview files in ~/Movies/Snazzy Pro/Interviews, which you can upload to OpsAPI later. To send them straight away, make an integration token in the OpsAPI dashboard (Interviews › Settings) and paste it here.")
                    .foregroundStyle(.secondary)
                TextField("OpsAPI address, e.g. https://api.example.com", text: $url)
                SecureField("Integration token (snz_…)", text: $token)
                Text("Candidates' answers, kits and decisions are sent to that server. The token is kept in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.callout) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                if !iv.isLinked {
                    Button("Link") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do {
                                try await iv.linkOpsAPI(url: url, token: token)
                                token = ""
                                status = "Linked."
                            } catch { status = error.localizedDescription }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || url.isEmpty || token.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// While the model turns a job description into a kit.
struct DraftingView: View {
    let jobDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Drafting competencies, questions and rubric from the job description…").font(.title3.bold())
            }
            Text(jobDescription)
                .font(.body)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text("You'll check and edit everything, and nothing is used until you approve it.").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Shown in place of the recruiter's windows while a candidate uses this Mac.
struct InterviewModeLock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("An interview is in progress").font(.title2.bold())
            Text("The assistant, the prompter and the recruiter's windows are off until the interview is unlocked.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Unlock (Mac owner)") { Task { await model.interviews.leaveInterviewMode() } }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
