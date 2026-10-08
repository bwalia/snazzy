import AppKit
import Builder
import Foundation
import Observation
import SnazzyCore
import UniformTypeIdentifiers

/// Sharing work between Snazzy Pro users with `.snazzy` files: a Builder
/// project plus, optionally, presets and the background images they use.
///
/// Nothing is sent anywhere by Snazzy Pro itself. The user picks AirDrop,
/// Messages, Mail or a folder, after seeing exactly what's included.
@MainActor @Observable
final class SharingController {
    struct ExportDraft: Equatable {
        var project: String?
        var presetNames: Set<String> = []
        var includeBackgrounds = true
        var note = ""
    }

    struct PendingImport: Identifiable {
        let id = UUID()
        let fileName: String
        let share: SnazzyShare
    }

    /// Non-nil while the Share sheet is open.
    var exportDraft: ExportDraft?
    /// Non-nil while the Import sheet is open.
    var pendingImport: PendingImport?
    /// A short result or error message for an alert.
    var message: String?

    static let utType = UTType(exportedAs: SnazzyShare.typeIdentifier, conformingTo: .data)

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Export

    func beginExport(project: String? = nil) {
        app.presets.refresh()
        exportDraft = ExportDraft(project: project ?? app.builder.current?.name)
    }

    /// Builds the share file contents. Presets are shared without model
    /// settings (provider addresses and consent are personal); background
    /// images are included only if a shared preset uses them.
    func build(_ draft: ExportDraft) throws -> SnazzyShare {
        let project = try draft.project.map { try app.builder.workspace.shareProject($0) }
        let presets: [SettingsPreset] = app.presets.presets
            .filter { draft.presetNames.contains($0.name) }
            .map { var p = $0; p.app = nil; return p }
        var images: [SnazzyShare.Image] = []
        if draft.includeBackgrounds {
            let ids = presets.reduce(into: Set<String>()) { $0.formUnion(SnazzyShare.imageIDs(in: $1)) }
            let library = app.capture.backgrounds
            for entry in library.images where ids.contains(entry.id) {
                if let data = try? Data(contentsOf: library.directory.appending(path: entry.file)) {
                    images.append(.init(id: entry.id, name: entry.name, data: data))
                }
            }
        }
        let title = draft.project ?? presets.first?.name ?? "Snazzy Pro"
        return SnazzyShare(title: title, note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                           project: project, presets: presets, backgrounds: images)
    }

    /// Things in the project that look like secrets, e.g. "app.js: GitHub token".
    func secretWarnings(_ share: SnazzyShare) -> [String] {
        guard let project = share.project else { return [] }
        return project.files.compactMap { file in
            guard file.data.count < 2_000_000, let text = String(data: file.data, encoding: .utf8) else { return nil }
            let hidden = SecretRedactor.redact(text).hidden
            return hidden.isEmpty ? nil : "\(file.path): \(Array(Set(hidden)).sorted().joined(separator: ", "))"
        }
    }

    /// Writes the share to a temporary file named after its title (for the share menu).
    func temporaryFile(for share: SnazzyShare) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Snazzy Share/\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(Self.fileName(share.title)).\(SnazzyShare.fileExtension)")
        try share.encoded().write(to: url, options: .atomic)
        return url
    }

    func saveWithPanel(_ share: SnazzyShare) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.utType]
        panel.nameFieldStringValue = "\(Self.fileName(share.title)).\(SnazzyShare.fileExtension)"
        panel.message = "Save a share file you can send to another Snazzy Pro user."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try share.encoded().write(to: url, options: .atomic)
            exportDraft = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = error.localizedDescription
        }
    }

    static func fileName(_ title: String) -> String {
        let cleaned = title.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "-" }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Snazzy Pro share" : String(name.prefix(80))
    }

    // MARK: Import

    func chooseFileToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.utType]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .snazzy file someone shared with you."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Reads a `.snazzy` file and asks the user before importing anything.
    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= SnazzyShare.maxCompressedBytes else { throw WorkspaceError("This file is too big to open.") }
            let share = try SnazzyShare.decode(Data(contentsOf: url))
            guard !share.isEmpty else { throw WorkspaceError("This share file is empty.") }
            pendingImport = PendingImport(fileName: url.lastPathComponent, share: share)
        } catch {
            message = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Imports the pending share: the project (under a free name), background
    /// images (as new library entries) and presets (renamed if the name is taken).
    func confirmImport() {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        let share = pending.share
        var done: [String] = []
        do {
            // The project first: it removes itself if it fails, so a failed import leaves nothing.
            if let project = share.project {
                let imported = try app.builder.workspace.importProject(project)
                app.builder.refreshProjects()
                app.builder.open(imported.name)
                app.sidePanelTab = .builder
                done.insert("“\(imported.name)” in the Builder", at: 0)
            }
            var idMap: [String: String] = [:]
            if !share.backgrounds.isEmpty {
                let tmp = FileManager.default.temporaryDirectory.appending(path: "Snazzy Import/\(UUID().uuidString.prefix(8))")
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                for image in share.backgrounds {
                    let file = tmp.appending(path: "\(Self.fileName(image.name)).img")
                    try image.data.write(to: file)
                    // add() decodes and re-encodes, so only real images get in.
                    if let entry = try? app.capture.backgrounds.add(file) { idMap[image.id] = entry.id }
                }
                if !idMap.isEmpty { done.append("\(idMap.count) background image\(idMap.count == 1 ? "" : "s")") }
            }
            for preset in share.presets {
                var p = SnazzyShare.remapImages(in: preset, idMap)
                p.app = nil
                p.name = freePresetName(p.name)
                try app.presets.store.save(p)
                done.append("preset “\(p.name)”")
            }
            app.presets.refresh()
            message = "Imported " + done.joined(separator: ", ") + "."
        } catch {
            message = "Import stopped: \(error.localizedDescription)"
        }
    }

    private func freePresetName(_ name: String) -> String {
        // Compared by file name: "lesson-setup" would otherwise overwrite "Lesson setup".
        let taken = Set(app.presets.presets.map { PresetStore.fileName($0.name) })
        guard taken.contains(PresetStore.fileName(name)) else { return name }
        var n = 1
        while true {
            let candidate = n == 1 ? "\(name) (shared)" : "\(name) (shared \(n))"
            if !taken.contains(PresetStore.fileName(candidate)) { return candidate }
            n += 1
        }
    }
}
