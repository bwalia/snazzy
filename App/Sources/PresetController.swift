import AppKit
import Foundation
import Observation
import SnazzyCore

/// Named settings presets: save the current setup, load another, list, delete.
/// The assistant's preset tools and the Presets menu call these methods.
@MainActor @Observable
final class PresetController {
    private(set) var presets: [SettingsPreset] = []
    /// The preset most recently loaded or saved (shown in the UI).
    private(set) var activeName: String?

    @ObservationIgnored let store: PresetStore
    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel, store: PresetStore = PresetStore(directory: PresetStore.defaultDirectory())) {
        self.app = app
        self.store = store
        refresh()
        activeName = UserDefaults.standard.string(forKey: "SnazzyPro.activePreset")
    }

    func refresh() {
        presets = store.list()
    }

    @discardableResult
    func save(name: String, notes: String = "", parts: PresetParts = .all) throws -> SettingsPreset {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw PresetError("Give the preset a name.") }
        let preset = SettingsPreset(
            name: n, notes: notes,
            capture: parts.contains(.capture) ? app.capture.setup : nil,
            app: parts.contains(.models) ? app.settings : nil)
        try store.save(preset)
        refresh()
        setActive(n)
        app.chat.logSession("preset_saved", ["name": .string(n)])
        return preset
    }

    /// Applies a preset (all of it, or only its capture or model part).
    @discardableResult
    func load(_ name: String, parts: PresetParts = .all) throws -> SettingsPreset {
        guard let preset = store.load(name) else {
            throw PresetError("No preset named “\(name)”. Presets: " + presets.map(\.name).joined(separator: ", "))
        }
        if parts.contains(.capture), let capture = preset.capture { app.capture.apply(capture) }
        if parts.contains(.models), let settings = preset.app { app.settings = settings }
        setActive(preset.name)
        app.chat.presetLoaded(preset.name)
        app.capture.diagnostics.log("Loaded preset \(preset.name)", category: "presets")
        return preset
    }

    func delete(_ name: String) throws {
        let deleted = try store.delete(name)
        if activeName.map(PresetStore.fileName) == PresetStore.fileName(deleted) { setActive(nil) }
        refresh()
    }

    private func setActive(_ name: String?) {
        activeName = name
        UserDefaults.standard.set(name, forKey: "SnazzyPro.activePreset")
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }

    /// Asks for a name and saves (menu command).
    func promptAndSave() {
        let alert = NSAlert()
        alert.messageText = "Save current settings as a preset"
        alert.informativeText = "Saves the microphone, screen, camera inset, layout and crop, and the model choices. API keys are not included."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "e.g. Q3 deck – iPad bottom-right"
        field.stringValue = activeName ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try save(name: field.stringValue) } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: For the assistant

    nonisolated static func summary(_ p: SettingsPreset) -> JSONValue {
        var out: [String: JSONValue] = ["name": .string(p.name), "updated": .string(ISO8601DateFormatter().string(from: p.updated))]
        if !p.notes.isEmpty { out["notes"] = .string(p.notes) }
        if let c = p.capture {
            var capture: [String: JSONValue] = [:]
            if let mic = c.mic { capture["microphone"] = .string(mic.name) }
            switch c.source {
            case .display(_, let name)?: capture["record"] = .string("display: \(name)")
            case .window(_, let a, let t)?: capture["record"] = .string("window: \(a) \(t)")
            case .slides?: capture["record"] = "slides"
            case nil: break
            }
            capture["inset_camera"] = c.insetDevice.map { .string($0.name) } ?? "none"
            capture["inset_position"] = .string(c.layout.corner.rawValue)
            capture["inset_size"] = .number(c.layout.size)
            out["capture"] = .object(capture)
        }
        if let a = p.app {
            out["models"] = .object(Dictionary(uniqueKeysWithValues: AssistantTask.allCases.map { t in
                let s = a.selection(for: t)
                return (t.rawValue, .string("\(s.provider.rawValue): \(s.model)"))
            }))
        }
        return .object(out)
    }

    func listJSON() -> JSONValue {
        ["active_preset": activeName.map(JSONValue.string) ?? .null, "presets": .array(presets.map(Self.summary))]
    }
}
