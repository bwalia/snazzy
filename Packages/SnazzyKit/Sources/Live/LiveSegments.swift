import Foundation
import SnazzyCore

/// The live stream as fragmented MP4: one init segment and a sliding window of
/// recent media segments. Browsers play it with HLS (Safari) or by fetching
/// segments into Media Source Extensions (Chrome, Edge, Firefox, iPad/iPhone).
public final class LiveSegments: @unchecked Sendable {
    public struct Segment: Sendable, Equatable {
        public let sequence: Int
        public let duration: Double
        public let data: Data
    }

    private let lock = NSLock()
    private var initSegment: Data?
    private var codecs = "avc1.640028,mp4a.40.2"
    private var segments: [Segment] = []
    private var nextSequence = 0
    /// Changes when the stream restarts (new init segment), so players reload.
    private var generation = 0
    public let window: Int

    public init(window: Int = 8) {
        self.window = window
    }

    public func setInit(_ data: Data) {
        let found = Self.codecs(in: data)
        lock.withLock {
            initSegment = data
            if let found { codecs = found }
            segments.removeAll()
            generation += 1
        }
    }

    /// The RFC 6381 codecs string for Media Source players, from the H.264
    /// `avcC` box (profile, compatibility, level) and an AAC track if present.
    static func codecs(in initSegment: Data) -> String? {
        guard let r = initSegment.range(of: Data("avcC".utf8)), initSegment.count >= r.upperBound + 4 else { return nil }
        let b = initSegment[r.upperBound...]
        let i = b.startIndex
        let avc = String(format: "avc1.%02x%02x%02x", b[i + 1], b[i + 2], b[i + 3])
        return initSegment.range(of: Data("mp4a".utf8)) != nil ? "\(avc),mp4a.40.2" : avc
    }

    public func append(_ data: Data, duration: Double) {
        lock.withLock {
            segments.append(Segment(sequence: nextSequence, duration: duration, data: data))
            nextSequence += 1
            if segments.count > window { segments.removeFirst(segments.count - window) }
        }
    }

    public func reset() {
        lock.withLock {
            initSegment = nil
            segments.removeAll()
            generation += 1
        }
    }

    public var isLive: Bool { lock.withLock { initSegment != nil && !segments.isEmpty } }

    public func initData() -> Data? { lock.withLock { initSegment } }

    public func segment(_ sequence: Int) -> Segment? {
        lock.withLock { segments.first { $0.sequence == sequence } }
    }

    /// What a Media Source player needs to stay at the live edge.
    public func statusJSON() -> JSONValue {
        lock.withLock {
            [
                "live": .bool(initSegment != nil && !segments.isEmpty),
                "codecs": .string(codecs),
                "generation": .number(Double(generation)),
                "segments": .array(segments.map { ["seq": .number(Double($0.sequence)), "duration": .number($0.duration)] }),
            ]
        }
    }

    /// An HLS media playlist (version 7, fMP4) for native players.
    public func playlist(query: String) -> String? {
        lock.withLock {
            guard initSegment != nil, let first = segments.first else { return nil }
            let target = Int((segments.map(\.duration).max() ?? 1).rounded(.up))
            var lines = [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-TARGETDURATION:\(max(1, target))",
                "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)",
                "#EXT-X-DISCONTINUITY-SEQUENCE:\(generation)",
                "#EXT-X-MAP:URI=\"init.mp4?\(query)\"",
            ]
            for s in segments {
                lines.append(String(format: "#EXTINF:%.3f,", s.duration))
                lines.append("seg-\(s.sequence).m4s?\(query)")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
}
