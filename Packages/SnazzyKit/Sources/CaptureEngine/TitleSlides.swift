import Foundation
import SnazzyCore

/// The camera bigger on title slides, smaller on the rest: its size at any moment,
/// from the slide changes. Live recording and New Layout both use this, so a
/// recording made again looks the same.
public enum TitleSlides {
    public struct Change: Equatable, Sendable {
        /// Seconds (on whatever clock the caller uses).
        public var at: Double
        public var isTitle: Bool

        public init(at: Double, isTitle: Bool) {
            self.at = at
            self.isTitle = isTitle
        }
    }

    /// How long the camera takes to grow or shrink.
    public static let transition = 0.4

    /// Slide changes from timeline.json markers, in raw-track time. Markers from before
    /// title slides were noted have no `title_slide` and are skipped.
    public static func changes(fromTimeline markers: [JSONValue]) -> [Change] {
        markers.compactMap { m in
            guard m["type"]?.stringValue == "slide", let at = m["at_seconds"]?.doubleValue,
                  let title = m["title_slide"]?.boolValue else { return nil }
            return Change(at: at, isTitle: title)
        }
        .sorted { $0.at < $1.at }
    }

    /// The inset size at `time`: `title` on title slides, `normal` otherwise, easing
    /// between them over `transition` after each change. The first slide applies at once.
    public static func insetSize(at time: Double, changes: [Change], normal: Double, title: Double) -> Double {
        guard let i = changes.lastIndex(where: { $0.at <= time }) else { return normal }
        let target = changes[i].isTitle ? title : normal
        guard i > 0 else { return target }
        let from = changes[i - 1].isTitle ? title : normal
        return ease(from: from, to: target, progress: (time - changes[i].at) / transition)
    }

    /// Smooth start and finish (smoothstep).
    public static func ease(from: Double, to: Double, progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return from + (to - from) * p * p * (3 - 2 * p)
    }
}
