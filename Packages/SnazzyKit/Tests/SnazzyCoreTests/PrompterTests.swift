import CoreGraphics
import Foundation
import Testing
@testable import SnazzyCore

@Suite struct PrompterTests {
    @Test func scrollsAtReadingSpeed() {
        // 140 words at 140 wpm take a minute: 600 points of text move 10 points a second.
        let text = Array(repeating: "word", count: 140).joined(separator: " ")
        #expect(abs(Prompter.pointsPerSecond(text: text, contentHeight: 600, wordsPerMinute: 140) - 10) < 0.001)
        #expect(Prompter.pointsPerSecond(text: "  \n ", contentHeight: 600, wordsPerMinute: 140) == 0)
        #expect(Prompter.wordCount("Hello,\nworld  again") == 3)
    }

    @Test func sitsUnderTheCamera() {
        // A 1512×945 visible area (below the menu bar) at the origin.
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let f = Prompter.frameUnderCamera(visible: visible, width: 640, height: 220)
        #expect(f.midX == visible.midX && f.maxY == visible.maxY - 6 && f.size == CGSize(width: 640, height: 220))
        // Never bigger than the screen, on a second screen to the left too.
        let small = Prompter.frameUnderCamera(visible: CGRect(x: -800, y: 100, width: 600, height: 150), width: 640, height: 220)
        #expect(small.minX >= -800 && small.maxX <= -200 && small.minY >= 100)
    }

    @Test func settingsDecodeTolerantly() throws {
        let s = try JSONDecoder().decode(PrompterSettings.self, from: Data(#"{"source":"script","script":"Hi","fontSize":500}"#.utf8))
        #expect(s.source == .script && s.script == "Hi" && s.fontSize == PrompterSettings.fontRange.upperBound && s.wordsPerMinute == 140)
        #expect(try JSONDecoder().decode(PrompterSettings.self, from: Data("{}".utf8)) == PrompterSettings())
    }
}
