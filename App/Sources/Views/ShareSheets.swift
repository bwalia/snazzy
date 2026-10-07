import Builder
import SnazzyCore
import SwiftUI

/// "Share…" for a project and presets: shows exactly what goes in the file
/// before the user sends it with AirDrop, Messages, Mail or saves it.
struct ShareExportSheet: View {
    @Environment(AppModel.self) private var model
    @State var draft: SharingController.ExportDraft
    @State private var share: SnazzyShare?
    @State private var fileURL: URL?
    @State private var error: String?

    var body: some View {
        let sharing = model.sharing!
        VStack(alignment: .leading, spacing: 14) {
            Text("Share with another Snazzy Pro user").font(.title3.weight(.semibold))
            Text("Creates a .snazzy file. The other person opens it to get your work in their Builder. API keys, conversations and recordings are never included.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Picker("Project", selection: $draft.project) {
                    Text("None").tag(String?.none)
                    ForEach(model.builder.projects) { p in
                        Text("\(p.name) (\(p.kind == .presentation ? "deck" : "prototype"))").tag(Optional(p.name))
                    }
                }
                if !model.presets.presets.isEmpty {
                    LabeledContent("Presets") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.presets.presets) { p in
                                Toggle(p.name, isOn: Binding(
                                    get: { draft.presetNames.contains(p.name) },
                                    set: { on in if on { draft.presetNames.insert(p.name) } else { draft.presetNames.remove(p.name) } }))
                            }
                            Text("Shared without your model settings.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Include background images the presets use", isOn: $draft.includeBackgrounds)
                        .disabled(draft.presetNames.isEmpty)
                }
                TextField("Note (optional)", text: $draft.note, prompt: Text("Here's the deck for Monday"))
            }
            .formStyle(.grouped)
            .frame(maxHeight: 320)

            GroupBox("What's in the file") {
                VStack(alignment: .leading, spacing: 4) {
                    if let share, !share.isEmpty {
                        ForEach(share.contentsSummary, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.callout) }
                        if let bytes = fileURL.flatMap({ try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) {
                            Text("File size: \(SnazzyShare.formatBytes(bytes))").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Pick a project or a preset to share.").font(.callout).foregroundStyle(.secondary)
                    }
                    if let share {
                        ForEach(sharing.secretWarnings(share), id: \.self) { w in
                            Label("Looks like a secret — check before sending: \(w)", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                    if let error { Label(error, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button("Cancel") { sharing.exportDraft = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save As…") { if let share { sharing.saveWithPanel(share) } }
                    .disabled(share?.isEmpty ?? true)
                if let fileURL, share?.isEmpty == false {
                    ShareLink(item: fileURL) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Share…") {}.disabled(true)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task(id: draft) { rebuild() }
    }

    private func rebuild() {
        do {
            let s = try model.sharing.build(draft)
            share = s
            fileURL = s.isEmpty ? nil : try model.sharing.temporaryFile(for: s)
            error = nil
        } catch {
            share = nil
            fileURL = nil
            self.error = error.localizedDescription
        }
    }
}

/// Shown when a .snazzy file is opened: what it contains, then Import.
struct ShareImportSheet: View {
    @Environment(AppModel.self) private var model
    let pending: SharingController.PendingImport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import “\(pending.share.title)”?").font(.title3.weight(.semibold))
            Text(pending.fileName).font(.caption).foregroundStyle(.secondary)
            if !pending.share.note.isEmpty {
                Text("“\(pending.share.note)”").font(.callout).italic()
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            GroupBox("It contains") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pending.share.contentsSummary, id: \.self) { Label($0, systemImage: "doc").font(.callout) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            Text("Projects are added alongside yours (nothing is replaced). Slide decks and prototypes are web pages, so only import files from people you know.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.sharing.pendingImport = nil }.keyboardShortcut(.cancelAction)
                Button("Import") { model.sharing.confirmImport() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Attaches the share and import sheets and the result alert to a view.
struct SharingSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let sharing = model.sharing!
        content
            .sheet(isPresented: Binding(get: { sharing.exportDraft != nil }, set: { if !$0 { sharing.exportDraft = nil } })) {
                if let draft = sharing.exportDraft { ShareExportSheet(draft: draft).environment(model) }
            }
            .sheet(item: Binding(get: { sharing.pendingImport }, set: { sharing.pendingImport = $0 })) { pending in
                ShareImportSheet(pending: pending).environment(model)
            }
            .alert("Sharing", isPresented: Binding(get: { sharing.message != nil }, set: { if !$0 { sharing.message = nil } })) {
                Button("OK") { sharing.message = nil }
            } message: {
                Text(sharing.message ?? "")
            }
    }
}
