import Assistant
import CaptureEngine
import Foundation
import SnazzyCore

/// Assistant tools for the developer features. Each is only offered when its
/// feature is turned on in Settings › Developer.
@MainActor
enum DeveloperTools {
    static func tools(_ dev: DeveloperController) -> [RegisteredTool] {
        let s = dev.settings
        var tools: [RegisteredTool] = [
            RegisteredTool(
                name: "list_recordings",
                description: "List the user's recordings (newest first) with their recording_id, length, and whether captions or a summary exist.",
                inputSchema: AssistantTools.emptySchema
            ) { @Sendable _ in await dev.recordingsJSON() },
        ]
        if s.trimEnabled {
            tools.append(RegisteredTool(
                name: "trim_recording",
                description: "Trim a recording to a time range; saves '<name> (trimmed).mp4' (and trimmed raw tracks) next to it, never changing the original. end_seconds may be negative to count from the end (-3 drops the last 3 seconds). recording_id can be \"latest\". Call list_recordings first to know the length.",
                inputSchema: AssistantTools.object([
                    "recording_id": ["type": "string", "minLength": 1],
                    "start_seconds": ["type": "number", "minimum": 0],
                    "end_seconds": ["type": "number"],
                ], required: ["recording_id", "start_seconds", "end_seconds"])
            ) { @Sendable args in
                let item = try await dev.recording(args["recording_id"]?.stringValue)
                let r = try await dev.trim(item, start: args["start_seconds"]?.doubleValue ?? 0, end: args["end_seconds"]?.doubleValue ?? -0)
                return ["file": .string(r.video.lastPathComponent), "duration_seconds": .number((r.duration * 10).rounded() / 10),
                        "raw_tracks_trimmed": .bool(r.rawFolder != nil)]
            })
        }
        return tools
    }
}
