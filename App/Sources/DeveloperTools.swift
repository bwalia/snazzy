import Assistant
import CaptureEngine
import Foundation
import SnazzyCore

/// Assistant tools for the developer features. Each is only offered when its
/// feature is turned on in Settings › Developer.
@MainActor
enum DeveloperTools {
    static func tools(_ dev: DeveloperController, offMac: String?) -> [RegisteredTool] {
        let s = dev.settings
        var tools: [RegisteredTool] = [
            RegisteredTool(
                name: "list_recordings",
                description: "List the user's recordings (newest first) with their recording_id, length, and whether captions or a summary exist.",
                inputSchema: AssistantTools.emptySchema
            ) { @Sendable _ in await dev.recordingsJSON() },
        ]
        tools.append(RegisteredTool(
            name: "relayout_recording",
            description: "Make a recording again from its raw tracks with a new layout, as a new file next to it (the original is kept): move or resize the camera inset (corner, size), crop it (aspect, zoom, center_x/center_y), rotate it, change its background (none, blur, as_recorded), fix lip sync (video_delay_ms), hide the camera, export in 4K, or as a vertical 9:16 clip (resolution \"vertical\": screen on top, camera below, for Shorts, Reels, TikTok). start_seconds/end_seconds make just that part (at least 1 s), with its captions and chapters. Starts from the layout it was recorded with; pass only what should change. Takes about as long as the part with a background, less without. recording_id can be \"latest\".",
            inputSchema: AssistantTools.object([
                "recording_id": ["type": "string", "minLength": 1],
                "corner": ["type": "string", "enum": .array(InsetCorner.allCases.map { .string($0.rawValue) })],
                "size": ["type": "number", "minimum": 0.05, "maximum": 0.6],
                "border_width": ["type": "number", "minimum": 0, "maximum": 40],
                "corner_radius": ["type": "number", "minimum": 0, "maximum": 0.5],
                "aspect": ["type": "string", "description": "16:9, 4:3, 1:1, 9:16 or fit"],
                "zoom": ["type": "number", "minimum": 0.1, "maximum": 1],
                "center_x": ["type": "number", "minimum": 0, "maximum": 1],
                "center_y": ["type": "number", "minimum": 0, "maximum": 1],
                "rotation": ["type": "string", "enum": .array(InsetRotation.allCases.map { .string($0.rawValue) })],
                "video_delay_ms": ["type": "number", "minimum": -500, "maximum": 1000],
                "background": ["type": "string", "enum": ["as_recorded", "none", "blur"]],
                "hide_camera": ["type": "boolean"],
                "resolution": ["type": "string", "enum": ["1080p", "4K", "vertical"]],
                "start_seconds": ["type": "number", "minimum": 0],
                "end_seconds": ["type": "number", "minimum": 1],
            ], required: ["recording_id"])
        ) { @Sendable args in
            let item = try await dev.recording(args["recording_id"]?.stringValue)
            var options = try await dev.relayoutSource(item).original
            var c = InsetChanges()
            c.corner = args["corner"]?.stringValue.flatMap(InsetCorner.init(rawValue:))
            c.size = args["size"]?.doubleValue
            c.borderWidth = args["border_width"]?.doubleValue
            c.cornerRadius = args["corner_radius"]?.doubleValue
            c.aspect = args["aspect"]?.stringValue.flatMap(InsetChanges.parseAspect)
            c.zoom = args["zoom"]?.doubleValue
            c.centerX = args["center_x"]?.doubleValue
            c.centerY = args["center_y"]?.doubleValue
            c.rotation = args["rotation"]?.stringValue.flatMap(InsetRotation.init(rawValue:))
            c.videoDelayMs = args["video_delay_ms"]?.doubleValue
            switch args["background"]?.stringValue {
            case "none": c.background = CameraBackground.none
            case "blur": c.background = .blur(strength: 0.6)
            default: break
            }
            c.apply(layout: &options.layout, profile: &options.profile)
            if args["hide_camera"]?.boolValue == true { options.showCamera = false }
            switch args["resolution"]?.stringValue {
            case "4K": options.resolution = .uhd4K
            case "vertical": options.resolution = .vertical
            default: break
            }
            let start = args["start_seconds"]?.doubleValue, end = args["end_seconds"]?.doubleValue
            if start != nil || end != nil {
                let duration = try await dev.relayoutSource(item).duration
                let (s, e) = (start ?? 0, end ?? duration)
                guard e > s else { throw CaptureActionError(message: "end_seconds has to be after start_seconds.") }
                options.range = s...e
            }
            let url = try await dev.relayout(item, options: options)
            return ["file": .string(url.lastPathComponent), "resolution": .string(options.resolution.rawValue)]
        })
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
        if s.captionsEnabled {
            tools.append(RegisteredTool(
                name: "make_captions",
                description: "Make captions for a recording with on-device speech recognition: saves <name>.srt and <name>.vtt next to it. burn_in: true also saves '<name> (captioned).mp4' with captions drawn into the video. recording_id can be \"latest\".",
                inputSchema: AssistantTools.object([
                    "recording_id": ["type": "string", "minLength": 1],
                    "burn_in": ["type": "boolean"],
                ], required: ["recording_id"])
            ) { @Sendable args in
                let item = try await dev.recording(args["recording_id"]?.stringValue)
                let r = try await dev.makeCaptions(item, burnIn: args["burn_in"]?.boolValue ?? false)
                var out: [String: JSONValue] = ["srt": .string(r.srt.lastPathComponent), "vtt": .string(r.vtt.lastPathComponent),
                                                "caption_count": .number(Double(r.cues.count))]
                if let b = r.burned { out["captioned_video"] = .string(b.lastPathComponent) }
                return .object(out)
            })
            tools.append(RegisteredTool(
                name: "summarize_recording",
                description: "Write a short summary of a recording (title, 3–5 bullets, chapter times) from its transcript using the Writing model, saved as <name>.md. Makes captions first if needed. recording_id can be \"latest\".",
                inputSchema: AssistantTools.object(["recording_id": ["type": "string", "minLength": 1]], required: ["recording_id"])
            ) { @Sendable args in
                let item = try await dev.recording(args["recording_id"]?.stringValue)
                let url = try await dev.summarize(item)
                return ["file": .string(url.lastPathComponent), "summary": .string((try? String(contentsOf: url, encoding: .utf8)) ?? "")]
            })
        }
        if s.shareEnabled {
            tools.append(RegisteredTool(
                name: "share_recording",
                description: "Upload a recording to the user's own storage and get a link: target \"s3\" (their bucket, time-limited link), \"github\" (a release asset in their repo) or \"gist\" (summary and captions as a secret Gist). The user sees the file, size and destination and must approve. Returns the link and text ready to paste into Slack, a GitHub PR comment or Jira.",
                inputSchema: AssistantTools.object([
                    "recording_id": ["type": "string", "minLength": 1],
                    "target": ["type": "string", "enum": ["s3", "github", "gist"]],
                ], required: ["recording_id", "target"])
            ) { @Sendable args in
                let item = try await dev.recording(args["recording_id"]?.stringValue)
                let target = ShareService.Target(rawValue: args["target"]?.stringValue ?? "") ?? .s3
                let o = try await dev.share.share(item, to: target)
                await MainActor.run { dev.lastShare = o }
                return ["link": .string(o.record.url), "copied_to_clipboard": true, "slack": .string(o.slack),
                        "github_pr_comment": .string(o.githubComment), "jira": .string(o.jira)]
            })
        }
        if s.pullRequestDemosEnabled {
            tools.append(RegisteredTool(
                name: "load_pull_request",
                description: "Load a GitHub pull request to make a demo: title, description, changed files and diff (cut if very long). repo is \"owner/repo\" or the PR's URL. Then plan a 2–4 slide demo deck and talk script and ask whether to record.",
                inputSchema: AssistantTools.object([
                    "repo": ["type": "string", "minLength": 3],
                    "number": ["type": "integer", "minimum": 1],
                ], required: ["repo"]),
                external: "GitHub"
            ) { @Sendable args in
                try await dev.loadPullRequest(args["repo"]?.stringValue ?? "", number: args["number"]?.intValue, offMac: offMac)
            })
            tools.append(RegisteredTool(
                name: "load_git_changes",
                description: "Load the changes on the current branch of a local repository the user allowed, compared with base_branch (e.g. \"main\"). The branch must be pushed to GitHub. path is the folder name or path (optional when only one folder is allowed).",
                inputSchema: AssistantTools.object([
                    "path": ["type": "string"],
                    "base_branch": ["type": "string", "minLength": 1],
                ], required: ["base_branch"]),
                external: "GitHub"
            ) { @Sendable args in
                try await dev.loadGitChanges(path: args["path"]?.stringValue, base: args["base_branch"]?.stringValue ?? "main", offMac: offMac)
            })
        }
        if s.screenReadingEnabled {
            tools.append(RegisteredTool(
                name: "read_front_window",
                description: "Read the text in the user's frontmost window of another app (terminal, editor, Xcode, browser) with on-device text recognition, so you can explain errors or output. With a cloud model, likely secrets are hidden and the user approves the text first.",
                inputSchema: AssistantTools.emptySchema,
                external: "the screen"
            ) { @Sendable _ in try await dev.readFrontWindow(offMac: offMac) })
        }
        if s.zoomEnabled {
            let capture = dev.app.capture
            tools.append(RegisteredTool(
                name: "zoom_screen",
                description: "Zoom the recording into the part of the recorded screen that shows some text (e.g. \"error:\" or a function name), then zoom back out after hold_seconds (default 6; 0 = stay zoomed). reset: true zooms back out now.",
                inputSchema: AssistantTools.object([
                    "text": ["type": "string", "minLength": 1],
                    "hold_seconds": ["type": "number", "minimum": 0, "maximum": 60],
                    "reset": ["type": "boolean"],
                ], required: []),
                external: "the screen"
            ) { @Sendable args in
                if args["reset"]?.boolValue == true {
                    await capture.animateZoom(to: nil)
                    return ["zoom": "reset"]
                }
                guard let text = args["text"]?.stringValue else { throw CaptureActionError(message: "Say which text to zoom to.") }
                let found = try await capture.zoom(toText: text, hold: args["hold_seconds"]?.doubleValue ?? 6)
                return ["zoomed_to": .string(found)]
            })
        }
        return tools
    }
}
