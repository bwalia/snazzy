import CoreGraphics
import Foundation

/// The camera prompter's settings: what it shows and how it scrolls.
public struct PrompterSettings: Codable, Equatable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        /// The current slide's speaker notes (follows the slides).
        case notes
        /// A script the user typed or pasted.
        case script
    }

    public var source: Source = .notes
    public var script = ""
    public var fontSize: Double = 30
    /// Reading speed; the text scrolls so it's read at this pace.
    public var wordsPerMinute: Double = 140
    /// How dark the background is (0 clear … 1 black).
    public var opacity: Double = 0.8
    /// Start scrolling when a recording starts (and pause with it).
    public var followsRecording = true

    public static let fontRange: ClosedRange<Double> = 16...72
    public static let speedRange: ClosedRange<Double> = 60...260
    public static let maxScript = 20_000

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrompterSettings()
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? d.source
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? d.script
        fontSize = (try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize).clamped(to: Self.fontRange)
        wordsPerMinute = (try c.decodeIfPresent(Double.self, forKey: .wordsPerMinute) ?? d.wordsPerMinute).clamped(to: Self.speedRange)
        opacity = (try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity).clamped(to: 0.2...1)
        followsRecording = try c.decodeIfPresent(Bool.self, forKey: .followsRecording) ?? d.followsRecording
    }
}

public enum Prompter {
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// How fast to scroll (points per second) so `text`, laid out `contentHeight`
    /// points tall, is read at `wordsPerMinute`.
    public static func pointsPerSecond(text: String, contentHeight: Double, wordsPerMinute: Double) -> Double {
        let words = wordCount(text)
        guard words > 0, contentHeight > 0, wordsPerMinute > 0 else { return 0 }
        let seconds = Double(words) / wordsPerMinute * 60
        return contentHeight / seconds
    }

    /// Where the prompter goes by default: centred at the top of the screen's
    /// visible area, right under a built-in camera. AppKit coordinates
    /// (origin bottom-left).
    public static func frameUnderCamera(visible: CGRect, width: CGFloat, height: CGFloat, gap: CGFloat = 6) -> CGRect {
        let w = min(width, visible.width - 2 * gap)
        let h = min(height, visible.height - 2 * gap)
        return CGRect(x: (visible.midX - w / 2).rounded(), y: (visible.maxY - h - gap).rounded(), width: w, height: h)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
