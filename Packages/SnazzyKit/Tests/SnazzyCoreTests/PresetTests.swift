import Foundation
import Testing
@testable import SnazzyCore

@Suite struct PresetTests {
    func store() -> PresetStore {
        PresetStore(directory: FileManager.default.temporaryDirectory.appending(path: "snazzy-presets-\(UUID().uuidString)"))
    }

    @Test func saveLoadListDelete() throws {
        let s = store()
        defer { try? FileManager.default.removeItem(at: s.directory) }
        var capture = CaptureSetup(mic: MicSelection(uniqueID: "usb", name: "USB Mic"), source: .display(id: 2, name: "LG"))
        capture.layout.corner = .topLeft
        var app = AppSettings.default
        app.activeTask = .building
        try s.save(SettingsPreset(name: "Q3 deck – iPad", notes: "leadership", capture: capture, app: app))
        try s.save(SettingsPreset(name: "Demo", capture: CaptureSetup(), app: nil))

        let loaded = try #require(s.load("q3 deck – ipad"))
        #expect(loaded.capture == capture)
        #expect(loaded.app?.activeTask == .building)
        #expect(loaded.notes == "leadership")
        #expect(s.load("q3")?.name == "Q3 deck – iPad")   // partial match
        #expect(Set(s.list().map(\.name)) == ["Q3 deck – iPad", "Demo"])

        // Saving again keeps the creation date.
        let created = loaded.created
        try s.save(SettingsPreset(name: "Q3 deck – iPad", capture: CaptureSetup(), app: nil, date: Date().addingTimeInterval(100)))
        #expect(s.load("Q3 deck – iPad")?.created == created)

        // A partial name finds a preset to load, but never deletes one or lends its date to a new one.
        #expect(throws: PresetError.self) { try s.delete("q3") }
        try s.save(SettingsPreset(name: "Q3", capture: CaptureSetup(), app: nil, date: Date().addingTimeInterval(200)))
        #expect(s.load("Q3")?.created != created)
        try s.delete("q3")
        #expect(s.load("Q3 deck – iPad") != nil)

        try s.delete("demo")
        #expect(s.list().map(\.name) == ["Q3 deck – iPad"])
        #expect(throws: PresetError.self) { try s.delete("nope") }
    }

    @Test func fileNames() {
        #expect(PresetStore.fileName("Q3 deck – iPad!") == "q3-deck-ipad.json")
        #expect(PresetStore.fileName("///") == "preset.json")
    }
}
