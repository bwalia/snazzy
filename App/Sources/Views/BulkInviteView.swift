import AppKit
import Builder
import Interview
import SwiftUI
import UniformTypeIdentifiers

/// Invite many candidates at once to an approved kit: paste a list, and each
/// candidate gets their own link (browser or Snazzy Pro). The pack is encrypted
/// on this Mac and uploaded once; OpsAPI runs every interview, in parallel.
struct BulkInviteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kit: RoleKit
    @State private var list = ""
    @State private var days = 7
    @State private var intro: String = ""
    @State private var running = false
    @State private var error: String?
    @State private var results: OpsAPILink.InviteResults?
    @State private var importing = false
    @State private var copied = false

    private var invitees: [OpsAPILink.Invitee] { OpsAPILink.Invitee.parse(list) }
    private var decks: [BuilderProject] { model.builder.projects.filter { $0.kind == .presentation } }

    var body: some View {
        let iv = model.interviews!
        VStack(alignment: .leading, spacing: 14) {
            Text("Invite Candidates: \(kit.title)").font(.title2.bold())
            if let results {
                done(results)
            } else if !iv.isLinked {
                Text("Bulk invites go through OpsAPI, which runs the interviews (so many people can take them at once) and keeps the results. Link OpsAPI first in the Interviews window (OpsAPI…).")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("Close") { dismiss() } }
            } else {
                Text("One candidate per line: “Name, email”. Paste from a spreadsheet, or open a CSV. Each person gets their own link: no account or passcode, and it works on one device.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $list)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Text("\(invitees.count) candidate\(invitees.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open a CSV…") { importing = true }
                }
                Form {
                    Stepper("Links work for \(days) day\(days == 1 ? "" : "s")", value: $days, in: 1...30)
                    Picker("Introduction deck (optional)", selection: $intro) {
                        Text("None").tag("")
                        ForEach(decks) { Text($0.name).tag($0.name) }
                    }
                    .help("Shown to candidates before they start, in Snazzy Pro. It goes in the encrypted pack, media included.")
                }
                .formStyle(.columns)
                if let stage = iv.inviteStage {
                    HStack {
                        switch stage {
                        case .packing: ProgressView().controlSize(.small); Text("Encrypting the interview pack on this Mac…")
                        case .uploading(let f): ProgressView(value: f).frame(width: 200); Text("Uploading to secure storage…")
                        case .inviting: ProgressView().controlSize(.small); Text("Making \(invitees.count) invite links…")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.disabled(running)
                    Button("Invite \(invitees.count) Candidate\(invitees.count == 1 ? "" : "s")") { invite() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || invitees.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .task {
            // Opened with a list already filled in (see `InterviewController.bulkInviteRequest`).
            guard let request = model.interviews.bulkInviteRequest, request.kitID == kit.id else { return }
            model.interviews.bulkInviteRequest = nil
            list = request.list
            intro = request.intro
            if request.send {
                try? await Task.sleep(for: .seconds(3))
                invite()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { list = list.isEmpty ? text : list + "\n" + text }
        }
    }

    private func invite() {
        running = true
        error = nil
        let chosen = decks.first { $0.name == intro }
        let people = invitees
        Task {
            do {
                results = try await model.interviews.inviteInBulk(kit: kit, intro: chosen, invitees: people, days: days)
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }

    // MARK: Results

    private func done(_ r: OpsAPILink.InviteResults) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(r.invited) invited\(r.failed > 0 ? ", \(r.failed) not invited" : "")", systemImage: r.failed > 0 ? "exclamationmark.circle" : "checkmark.circle.fill")
                .font(.headline).foregroundStyle(r.failed > 0 ? .orange : .green)
            Text("Send each person their own link (copy them now: they aren't shown again). They can open it in a browser, or in Snazzy Pro to see the interview deck and answer by voice.")
                .font(.callout).foregroundStyle(.secondary)
            Table(r.results) {
                TableColumn("Name") { Text($0.name ?? "") }
                TableColumn("Email") { Text($0.email ?? "") }
                TableColumn("Link") { item in
                    if let url = item.url { Text(url).textSelection(.enabled).lineLimit(1).truncationMode(.middle) } else { Text(item.error ?? "").foregroundStyle(.orange) }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button(copied ? "Copied" : "Copy All Links") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.table(r), forType: .string)
                    copied = true
                }
                Button("Save as CSV…") { save(r) }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }

    /// Name, email, web link, Snazzy Pro link (tab-separated, pastes into a spreadsheet).
    static func table(_ r: OpsAPILink.InviteResults) -> String {
        (["Name\tEmail\tLink\tSnazzy Pro link"] + r.results.compactMap { i in
            guard let url = i.url else { return nil }
            return [i.name ?? "", i.email ?? "", url, i.appUrl ?? ""].joined(separator: "\t")
        }).joined(separator: "\n")
    }

    private func save(_ r: OpsAPILink.InviteResults) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Invites – \(kit.title).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let csv = (["Name,Email,Link,Snazzy Pro link"] + r.results.compactMap { i in
            guard let link = i.url else { return nil }
            return [i.name ?? "", i.email ?? "", link, i.appUrl ?? ""].map(cell).joined(separator: ",")
        }).joined(separator: "\n")
        do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
}
