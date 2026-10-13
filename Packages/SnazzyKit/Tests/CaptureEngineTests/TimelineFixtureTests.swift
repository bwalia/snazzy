import Foundation
import Testing
@testable import CaptureEngine
import SnazzyCore

/// timeline.json and .chapters.vtt fixtures for `docs/specs/recordings.md`
/// (see BuilderTests/SpecFixtureTests.swift). `SNAZZY_WRITE_FIXTURES=1` rewrites them.
@Suite struct TimelineFixtureTests {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/specs/fixtures", directoryHint: .isDirectory)
    static var writing: Bool { ProcessInfo.processInfo.environment["SNAZZY_WRITE_FIXTURES"] == "1" }

    static func check(_ name: String, _ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = directory.appending(path: name)
        if writing {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(throws: Never.self, sourceLocation: sourceLocation) { try data.write(to: url) }
            return
        }
        #expect((try? Data(contentsOf: url)) == data, "docs/specs/fixtures/\(name) is out of date: run SNAZZY_WRITE_FIXTURES=1 swift test",
                sourceLocation: sourceLocation)
    }

    static let start = Date(timeIntervalSince1970: 1_767_323_045)  // 2026-01-02T03:04:05Z

    static func slide(_ index: Int, _ title: String, at: Double, isTitle: Bool = false) -> JSONValue {
        ["type": "slide", "index": .number(Double(index)), "title": .string(title), "title_slide": .bool(isTitle), "at_seconds": .number(at)]
    }

    @Test func timelineAndChapters() throws {
        var profile = DeviceProfile.defaults(for: .camera)
        profile.videoDelayMs = 120
        profile.background = .blur(strength: 0.6)
        profile.rotation = .left
        var spec = CompositeSpec(layout: InsetLayout(corner: .topRight, size: 0.3, margin: 0.03, borderWidth: 4, cornerRadius: 0.1), profile: profile)
        spec.titleSlideInsetSize = 0.5
        let markers: [JSONValue] = [
            Self.slide(0, "Q3 review", at: 0.512, isTitle: true),
            Self.slide(1, "Revenue / costs", at: 4.25),
            Self.slide(2, "Flicked past", at: 30.1),
            Self.slide(3, "Costs --> margins", at: 30.9),
            Self.slide(3, "Costs --> margins", at: 45),
            ["type": "note", "text": "Something else", "at_seconds": 50],
            ["type": "slide", "index": 4, "at_seconds": 61.5],
        ]
        let result = RecordingResult(composite: URL(fileURLWithPath: "/recordings/presentation-20260102-030405.mov"),
                                     rawFolder: URL(fileURLWithPath: "/recordings/presentation-20260102-030405 raw"), duration: 75.0333,
                                     freezes: [CameraFeed.Freeze(start: Self.start.addingTimeInterval(12.5), duration: 2.25),
                                               CameraFeed.Freeze(start: Self.start.addingTimeInterval(-1), duration: 0)],
                                     droppedFrames: 3)
        let timeline = RecordingSession.timeline(result, recordingStart: Self.start, spec: spec, fps: 30, markers: markers,
                                                 sortedLatencies: [0.031, 0.034, 0.0405, 0.05], compositeStart: 0.4)
        Self.check("timeline.json", try timeline.encoded())

        var plain = spec
        plain.profile = DeviceProfile(crop: InsetCrop(aspect: nil))
        plain.titleSlideInsetSize = nil
        let minimal = RecordingSession.timeline(RecordingResult(composite: URL(fileURLWithPath: "/r/p.mov"), rawFolder: URL(fileURLWithPath: "/r/p raw"),
                                                                duration: 10, freezes: [], droppedFrames: 0),
                                                recordingStart: Self.start, spec: plain, fps: 30, markers: [], sortedLatencies: [], compositeStart: 0)
        Self.check("timeline-minimal.json", try minimal.encoded())

        let vtt = Chapters.vtt(Chapters.marks(fromTimeline: markers, start: 0.4), duration: 75.0333)
        Self.check("chapters.vtt", Data((vtt ?? "").utf8))
        #expect(Chapters.vtt(Chapters.marks(fromTimeline: [Self.slide(0, "Only", at: 1)], start: 0), duration: 10) == nil)
    }
}
