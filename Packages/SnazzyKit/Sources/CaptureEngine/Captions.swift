import Foundation

/// A transcribed word with its time in the recording.
public struct TimedWord: Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(_ text: String, _ start: Double, _ end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct CaptionCue: Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Groups words into readable caption cues and writes SRT / WebVTT.
public enum Captions {
    /// Readability limits (broadcast-style): ~2 lines of 42 characters, ≤ 6 s.
    public static let maxCharacters = 84
    public static let maxDuration = 6.0
    public static let pauseBreak = 0.8

    public static func cues(from words: [TimedWord]) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
            cues.append(CaptionCue(start: first.start, end: max(last.end, first.start + 0.7), text: wrap(text)))
            current = []
        }

        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = current.last, let first = current.first {
                let length = current.map(\.text).joined(separator: " ").count + 1 + word.text.count
                let pause = word.start - last.end
                if length > maxCharacters || word.end - first.start > maxDuration || pause > pauseBreak {
                    flush()
                }
            }
            current.append(word)
            // End a cue at a sentence end once it has some substance.
            if let w = current.last?.text, w.hasSuffix(".") || w.hasSuffix("?") || w.hasSuffix("!"),
               current.map(\.text).joined(separator: " ").count > 20 {
                flush()
            }
        }
        flush()
        // Cues must not overlap.
        for i in cues.indices.dropLast() where cues[i].end > cues[i + 1].start {
            cues[i].end = cues[i + 1].start
        }
        return cues
    }

    /// Splits long text into two balanced lines at a space.
    static func wrap(_ text: String, width: Int = 42) -> String {
        guard text.count > width else { return text }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let before = text[..<middle].lastIndex(of: " ")
        let after = text[middle...].firstIndex(of: " ")
        let split: String.Index? = switch (before, after) {
        case let (b?, a?): text.distance(from: b, to: middle) <= text.distance(from: middle, to: a) ? b : a
        case let (b?, nil): b
        case let (nil, a?): a
        default: nil
        }
        guard let split else { return text }
        return String(text[..<split]) + "\n" + String(text[text.index(after: split)...])
    }

    public static func srt(_ cues: [CaptionCue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(timestamp(c.start, separator: ",")) --> \(timestamp(c.end, separator: ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [CaptionCue]) -> String {
        "WEBVTT\n\n" + cues.map { c in
            "\(timestamp(c.start, separator: ".")) --> \(timestamp(c.end, separator: "."))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    /// HH:MM:SS,mmm (SRT) or HH:MM:SS.mmm (VTT).
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, separator, ms % 1000)
    }

    /// Transcript with a [mm:ss] marker every ~30 s, for summaries and chapters.
    public static func timedTranscript(_ cues: [CaptionCue], every interval: Double = 30) -> String {
        var out = ""
        var nextMarker = 0.0
        for cue in cues {
            if cue.start >= nextMarker {
                out += (out.isEmpty ? "" : "\n") + "[\(String(format: "%02d:%02d", Int(cue.start) / 60, Int(cue.start) % 60))] "
                nextMarker = cue.start + interval
            }
            out += cue.text.replacingOccurrences(of: "\n", with: " ") + " "
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Chapters from slide changes, as a WebVTT chapters file next to the movie.
public enum Chapters {
    public struct Mark: Equatable, Sendable {
        /// Seconds from the start of the movie.
        public var at: Double
        public var title: String

        public init(at: Double, title: String) {
            self.at = at
            self.title = title
        }
    }

    /// `presentation-….mov` → `presentation-….chapters.vtt`.
    public static func url(forMovie movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("chapters.vtt")
    }

    /// Chapters from marks: slides shown under `minimum` seconds are skipped
    /// (flicking past them), repeats are merged, the first starts at 0.
    /// Nil when there are fewer than two chapters.
    public static func vtt(_ marks: [Mark], duration: Double, minimum: Double = 1.5) -> String? {
        let sorted = marks.map { Mark(at: min(max(0, $0.at), duration), title: $0.title) }.sorted { $0.at < $1.at }
        var kept: [Mark] = []
        for (i, m) in sorted.enumerated() {
            let end = i + 1 < sorted.count ? sorted[i + 1].at : duration
            guard end - m.at >= minimum else { continue }
            if kept.last?.title == m.title { continue }
            kept.append(m)
        }
        guard kept.count >= 2 else { return nil }
        kept[0].at = 0
        let cues = kept.enumerated().map { i, m -> String in
            let end = i + 1 < kept.count ? kept[i + 1].at : duration
            let title = m.title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "-->", with: "→")
            return "\(i + 1)\n\(Captions.timestamp(m.at, separator: ".")) --> \(Captions.timestamp(end, separator: "."))\n\(title)\n"
        }
        return "WEBVTT\n\n" + cues.joined(separator: "\n")
    }
}
