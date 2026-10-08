@preconcurrency import AVFoundation
import Foundation
import SnazzyCore

/// Edits made after recording. Originals are never changed: every result is a
/// new file next to the original.
public enum RecordingEditor {
    public struct TrimResult: Sendable {
        public var video: URL
        public var rawFolder: URL?
        public var duration: Double
    }

    /// The raw-tracks folder for a recording, if it exists.
    public static func rawFolder(for video: URL) -> URL? {
        let folder = video.deletingLastPathComponent().appending(path: video.deletingPathExtension().lastPathComponent + " raw", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// `<name> (<suffix>).<ext>`, numbered if that name is taken.
    public static func sibling(of url: URL, suffix: String, ext: String) -> URL {
        let dir = url.deletingLastPathComponent()
        var base = url.deletingPathExtension().lastPathComponent
        // Don't stack suffixes: "x (trimmed) (trimmed)" → "x (trimmed 2)".
        if base.hasSuffix(" (\(suffix))") { base = String(base.dropLast(suffix.count + 3)) }
        var candidate = dir.appending(path: "\(base) (\(suffix)).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: "\(base) (\(suffix) \(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Resolves a requested range against a duration. A negative `end` counts
    /// back from the end ("-3" drops the last 3 seconds).
    public static func resolveRange(start: Double, end: Double, duration: Double) throws -> (Double, Double) {
        let s = max(0, start)
        let e = end < 0 ? duration + end : min(end, duration)
        guard e - s >= 0.5 else {
            throw CaptureError("That leaves less than half a second (recording is \(String(format: "%.1f", duration)) s long).")
        }
        return (s, e)
    }

    /// Trims a recording (and its raw tracks, so they stay in step) without re-encoding.
    public static func trim(_ video: URL, start: Double, end: Double) async throws -> TrimResult {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let (s, e) = try resolveRange(start: start, end: end, duration: duration)
        let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), end: CMTime(seconds: e, preferredTimescale: 600))
        let output = sibling(of: video, suffix: "trimmed", ext: "mp4")
        try await export(asset, range: range, to: output, fileType: .mp4)

        var trimmedRaw: URL?
        if let raw = rawFolder(for: video) {
            let timeline = (try? JSONValue.parse(Data(contentsOf: raw.appending(path: "timeline.json")))) ?? [:]
            let offset = timeline["composite_starts_at_seconds"]?.doubleValue ?? 0
            let rawRange = CMTimeRange(start: CMTime(seconds: s + offset, preferredTimescale: 600),
                                       end: CMTime(seconds: e + offset, preferredTimescale: 600))
            let folder = output.deletingLastPathComponent()
                .appending(path: output.deletingPathExtension().lastPathComponent + " raw", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["screen.mov", "camera.mov", "mic.mov"] {
                let source = raw.appending(path: name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let rawAsset = AVURLAsset(url: source)
                let rawDuration = try await rawAsset.load(.duration)
                let clipped = CMTimeRangeGetIntersection(rawRange, otherRange: CMTimeRange(start: .zero, duration: rawDuration))
                guard clipped.duration.seconds > 0 else { continue }
                try await export(rawAsset, range: clipped, to: folder.appending(path: name), fileType: .mov)
            }
            let trimmed = trimmedTimeline(timeline, start: s + offset, end: e + offset, duration: e - s, video: output)
            try trimmed.encoded().write(to: folder.appending(path: "timeline.json"))
            // The trimmed copy keeps its slide chapters.
            if let vtt = Chapters.vtt(Chapters.marks(fromTimeline: trimmed["markers"]?.arrayValue ?? [], start: 0), duration: e - s) {
                try? vtt.write(to: Chapters.url(forMovie: output), atomically: true, encoding: .utf8)
            }
            trimmedRaw = folder
        }
        return TrimResult(video: output, rawFolder: trimmedRaw, duration: e - s)
    }

    /// The timeline for a trimmed copy whose raw tracks cover `start…end` of the
    /// original's raw time: times shift to the new start; freezes and markers
    /// outside the range are dropped.
    static func trimmedTimeline(_ timeline: JSONValue, start: Double, end: Double, duration: Double, video: URL) -> JSONValue {
        var t = timeline.objectValue ?? [:]
        t["duration_seconds"] = .number(duration)
        t["composite"] = .string(video.lastPathComponent)
        t["composite_starts_at_seconds"] = 0
        t["trimmed_from"] = ["start_seconds": .number(start), "end_seconds": .number(end)]
        t["markers"] = .array((timeline["markers"]?.arrayValue ?? []).compactMap { m -> JSONValue? in
            guard var o = m.objectValue, let at = m["at_seconds"]?.doubleValue, at <= end else { return nil }
            o["at_seconds"] = .number(max(0, at - start))
            return .object(o)
        })
        let freezes = (timeline["camera_freezes"]?.arrayValue ?? []).compactMap { f -> JSONValue? in
            guard let at = f["at_seconds"]?.doubleValue else { return nil }
            let d = f["duration_seconds"]?.doubleValue ?? 0
            guard at + d >= start, at <= end else { return nil }
            return ["at_seconds": .number(max(0, at - start)), "duration_seconds": .number(d)]
        }
        t["camera_freezes"] = .array(freezes)
        return .object(t)
    }

    /// Exports a time range. Pass-through (no re-encoding) when possible.
    static func export(_ asset: AVAsset, range: CMTimeRange, to url: URL, fileType: AVFileType) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError("This recording can't be exported.")
        }
        session.timeRange = range
        try await session.export(to: url, as: fileType)
    }
}
