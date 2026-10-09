import Foundation
import Testing
@testable import CaptureEngine
@testable import SnazzyCore

@Suite struct TitleSlidesTests {
    let changes = [TitleSlides.Change(at: 0, isTitle: true), TitleSlides.Change(at: 5, isTitle: false), TitleSlides.Change(at: 10, isTitle: true)]

    @Test func sizeFollowsTheSlides() {
        func size(_ t: Double) -> Double { TitleSlides.insetSize(at: t, changes: changes, normal: 0.28, title: 0.5) }
        #expect(size(0) == 0.5)                      // the first slide applies at once
        #expect(size(4.9) == 0.5)
        #expect(size(5) == 0.5)                      // easing starts at the change…
        #expect(size(5.2) > 0.28 && size(5.2) < 0.5)
        #expect(size(5.4) == 0.28)                   // …and is done after 0.4 s
        #expect(size(10.4) == 0.5)
        #expect(TitleSlides.insetSize(at: 3, changes: [], normal: 0.28, title: 0.5) == 0.28)
    }

    @Test func readsTheTimelineMarkers() {
        let markers: [JSONValue] = [
            ["type": "slide", "at_seconds": 4, "title_slide": false],
            ["type": "slide", "at_seconds": 1, "title_slide": true],
            ["type": "slide", "at_seconds": 9],              // from before title slides were noted
            ["type": "zoom", "at_seconds": 2, "title_slide": true],
        ]
        #expect(TitleSlides.changes(fromTimeline: markers) == [TitleSlides.Change(at: 1, isTitle: true), TitleSlides.Change(at: 4, isTitle: false)])
    }
}
