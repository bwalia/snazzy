import Assistant
import Builder
import CaptureEngine
import Foundation
import SnazzyCore

/// Tool definitions for the assistant. Handlers call `CaptureController` (the
/// same actions as the buttons) and return the new state.
@MainActor
enum AssistantTools {
    /// `includeMCP: false` leaves out tools proxied from other MCP servers
    /// (used when Snazzy Pro itself serves MCP, to avoid loops).
    static func registry(app: AppModel, includeMCP: Bool = true) -> ToolRegistry {
        let capture = app.capture
        let builder = app.builder
        let corners: [JSONValue] = InsetCorner.allCases.map { .string($0.rawValue) }
        let rotations: [JSONValue] = InsetRotation.allCases.map { .string($0.rawValue) }

        return ToolRegistry([
            RegisteredTool(
                name: "get_project_state",
                description: "Get the current project state: assistant model, microphone, capture source, inset camera with its crop/rotation and live status, inset layout, open previews. Call this before making changes.",
                inputSchema: emptySchema
            ) { @Sendable _ in await app.projectState() },

            RegisteredTool(
                name: "list_devices",
                description: "List microphones, cameras (built-in, USB, Continuity Camera), iPad/iPhone screens connected by USB, displays and windows that can be recorded.",
                inputSchema: emptySchema
            ) { @Sendable _ in await capture.devicesJSON() },

            RegisteredTool(
                name: "select_mic",
                description: "Choose the microphone to record. Pass its name (or part of it, e.g. \"USB\") or ID from list_devices.",
                inputSchema: object(["name": ["type": "string", "description": "Microphone name, part of the name, or ID", "minLength": 1]],
                                    required: ["name"])
            ) { @Sendable args in
                try await capture.selectMic(args["name"]?.stringValue ?? "")
                return await capture.stateJSON()
            },

            RegisteredTool(
                name: "select_capture_source",
                description: "Choose what is recorded: a display (by name like \"LG\" or \"main\", or ID), a window (by app/title or ID), or the app's slides.",
                inputSchema: object([
                    "type": ["type": "string", "enum": ["display", "window", "slides"]],
                    "name": ["type": "string", "description": "Display or window name, part of it, or ID. Not needed for slides."],
                ], required: ["type"])
            ) { @Sendable args in
                let name = args["name"]?.stringValue ?? ""
                switch args["type"]?.stringValue {
                case "display": _ = try await capture.selectDisplay(name.isEmpty ? "main" : name)
                case "window": _ = try await capture.selectWindow(name)
                default: await capture.selectSlidesSource()
                }
                return await capture.stateJSON()
            },

            RegisteredTool(
                name: "select_inset_device",
                description: "Choose the camera shown as the picture-in-picture inset: an iPad/iPhone connected by USB, a USB webcam, the built-in camera or a Continuity Camera. Pass a name (\"iPad\", \"iPhone\", \"LG\") or ID, or \"none\" to remove the inset. Waits up to ~45 s for an iPad/iPhone to appear.",
                inputSchema: object(["device": ["type": "string", "minLength": 1]], required: ["device"])
            ) { @Sendable args in
                try await capture.selectInsetDevice(args["device"]?.stringValue ?? "")
                return await capture.stateJSON()
            },

            RegisteredTool(
                name: "set_inset",
                description: "Change the camera inset. Layout: position (corner), size (inset height as a fraction of the video height, 0.05–0.6), border_width (px), corner_radius (fraction of height). Crop of the device picture: aspect (\"16:9\", \"4:3\", \"1:1\", \"9:16\" or \"fit\" for the whole picture), zoom (0.1–1, smaller = tighter), center_x / center_y (0–1 from left/top; lower center_y moves the crop up, e.g. if the head is cut off), rotation (none, left = 90° anticlockwise, right, upsideDown; an iPhone held sideways usually needs left). Only pass what should change.",
                inputSchema: object([
                    "position": ["type": "string", "enum": .array(corners)],
                    "size": ["type": "number", "minimum": 0.05, "maximum": 0.6],
                    "border_width": ["type": "number", "minimum": 0, "maximum": 40],
                    "corner_radius": ["type": "number", "minimum": 0, "maximum": 0.5],
                    "aspect": ["type": "string", "enum": ["16:9", "4:3", "1:1", "9:16", "fit"]],
                    "zoom": ["type": "number", "minimum": 0.1, "maximum": 1],
                    "center_x": ["type": "number", "minimum": 0, "maximum": 1],
                    "center_y": ["type": "number", "minimum": 0, "maximum": 1],
                    "rotation": ["type": "string", "enum": .array(rotations)],
                ], required: [])
            ) { @Sendable args in
                var c = InsetChanges()
                c.corner = args["position"]?.stringValue.flatMap(InsetCorner.init(rawValue:))
                c.size = args["size"]?.doubleValue
                c.borderWidth = args["border_width"]?.doubleValue
                c.cornerRadius = args["corner_radius"]?.doubleValue
                c.aspect = args["aspect"]?.stringValue.flatMap(InsetChanges.parseAspect)
                c.zoom = args["zoom"]?.doubleValue
                c.centerX = args["center_x"]?.doubleValue
                c.centerY = args["center_y"]?.doubleValue
                c.rotation = args["rotation"]?.stringValue.flatMap(InsetRotation.init(rawValue:))
                try await capture.updateInset(c)
                return await capture.stateJSON()
            },

            RegisteredTool(
                name: "open_preview",
                description: "Open a floating live preview. view \"camera\" (default) shows a camera's inset region so the user can check framing; view \"recording\" shows exactly what will be recorded (screen + camera inset). Previews never appear in recordings.",
                inputSchema: object([
                    "view": ["type": "string", "enum": ["camera", "recording"]],
                    "device": ["type": "string", "description": "Camera name or ID for view camera; omit for the inset camera"],
                ], required: [])
            ) { @Sendable args in
                if args["view"]?.stringValue == "recording" {
                    await capture.openCompositePreview()
                } else {
                    let id = try await resolveDeviceID(args["device"]?.stringValue, capture: capture)
                    try await capture.openPreview(deviceID: id)
                }
                return await capture.stateJSON()
            },

            RegisteredTool(
                name: "close_preview",
                description: "Close floating previews: view \"recording\" closes the recording preview; otherwise the given camera's preview, or all camera previews if no device is given.",
                inputSchema: object(["view": ["type": "string", "enum": ["camera", "recording"]], "device": ["type": "string"]], required: [])
            ) { @Sendable args in
                if args["view"]?.stringValue == "recording" {
                    await capture.closeCompositePreview()
                    return await capture.stateJSON()
                }
                let id = try await resolveDeviceID(args["device"]?.stringValue, capture: capture)
                await capture.closePreview(deviceID: id)
                return await capture.stateJSON()
            },
            RegisteredTool(
                name: "set_background",
                description: "Change what's behind the person in the inset camera (on-device person segmentation; shows in previews and recordings). background: \"none\", \"blur\" (strength 0–1), a built-in (Spotlight, Ink, Studio grey, Warm studio, Ocean, Sunset, Bokeh), the name of an image the user added, or a #RRGGBB colour.",
                inputSchema: object([
                    "background": ["type": "string", "minLength": 1],
                    "strength": ["type": "number", "minimum": 0, "maximum": 1, "description": "Blur strength"],
                ], required: ["background"])
            ) { @Sendable args in
                let query = args["background"]?.stringValue ?? ""
                guard let bg = await capture.backgrounds.resolve(query, strength: args["strength"]?.doubleValue) else {
                    throw CaptureActionError(message: "No background called “\(query)”. Options: \(await capture.backgroundsJSON()["options"]?.compactString ?? "")")
                }
                try await capture.setBackground(bg)
                return await capture.backgroundsJSON()
            },
            RegisteredTool(
                name: "list_backgrounds",
                description: "List the camera backgrounds available (built-ins and the user's images) and which is active.",
                inputSchema: emptySchema
            ) { @Sendable _ in await capture.backgroundsJSON() },
        ] + recordingTools(capture) + builderTools(builder) + modelTools(app) + settingsTools(app)
          + (includeMCP ? app.mcp.registeredTools() : []))
    }

    // MARK: Recording

    static func recordingTools(_ capture: CaptureController) -> [RegisteredTool] {
        [
            RegisteredTool(
                name: "start_recording",
                description: "Start recording the selected display or window with the camera inset and the microphone, after a countdown (default 3 s). Saves automatically to Movies/Snazzy Pro/Recordings with a timestamped name, plus raw tracks.",
                inputSchema: object(["countdown": ["type": "integer", "minimum": 0, "maximum": 10]], required: [])
            ) { @Sendable args in
                try await capture.startRecording(countdown: args["countdown"]?.intValue ?? 3)
                return await capture.recordingJSON()
            },
            RegisteredTool(
                name: "pause_recording",
                description: "Pause the recording (the paused time is left out of the video).",
                inputSchema: emptySchema
            ) { @Sendable _ in
                await capture.pauseRecording()
                return await capture.recordingJSON()
            },
            RegisteredTool(
                name: "resume_recording",
                description: "Resume a paused recording.",
                inputSchema: emptySchema
            ) { @Sendable _ in
                await capture.resumeRecording()
                return await capture.recordingJSON()
            },
            RegisteredTool(
                name: "stop_recording",
                description: "Stop and save the recording. Returns the file paths, duration and any camera freezes.",
                inputSchema: emptySchema
            ) { @Sendable _ in
                await capture.stopRecording()
                return await capture.recordingJSON()
            },
        ]
    }

    // MARK: Builder

    static func builderTools(_ builder: BuilderController) -> [RegisteredTool] {
        let project: JSONValue = ["type": "string", "description": "Project name; omit for the open project"]
        return [
            RegisteredTool(
                name: "create_project",
                description: "Create (or reopen) a builder project with working starter files. kind \"prototype\" = interactive app prototype (index.html, style.css, app.js); kind \"presentation\" = 16:9 HTML slide deck (index.html with <section class=\"slide\"> elements, deck.css, deck.js handling navigation). The project opens in the Builder panel with a live preview.",
                inputSchema: object([
                    "name": ["type": "string", "minLength": 1, "description": "Short project name"],
                    "kind": ["type": "string", "enum": ["prototype", "presentation"]],
                    "title": ["type": "string", "description": "Title shown in the starter page"],
                ], required: ["name", "kind"])
            ) { @Sendable args in
                let kind = ProjectKind(rawValue: args["kind"]?.stringValue ?? "") ?? .prototype
                try await builder.createProject(name: args["name"]?.stringValue ?? "", kind: kind, title: args["title"]?.stringValue)
                return try await builder.reloadAndReport()
            },
            RegisteredTool(
                name: "write_file",
                description: "Create or replace a file in the project with its COMPLETE content (no diffs or placeholders). The preview reloads; the result includes console_errors and a page summary. Fix any errors you see.",
                inputSchema: object([
                    "path": ["type": "string", "minLength": 1, "description": "Relative path, e.g. index.html or js/app.js"],
                    "content": ["type": "string", "description": "Full file content"],
                    "project": project,
                ], required: ["path", "content"])
            ) { @Sendable args in
                try await builder.writeFile(project: args["project"]?.stringValue, path: args["path"]?.stringValue ?? "",
                                            content: args["content"]?.stringValue ?? "")
            },
            RegisteredTool(
                name: "read_file",
                description: "Read a file from the project.",
                inputSchema: object(["path": ["type": "string", "minLength": 1], "project": project], required: ["path"])
            ) { @Sendable args in
                .string(try await builder.readFile(project: args["project"]?.stringValue, path: args["path"]?.stringValue ?? ""))
            },
            RegisteredTool(
                name: "list_files",
                description: "List the open project's files, or all projects if none is open.",
                inputSchema: object(["project": project], required: [])
            ) { @Sendable args in
                if let name = args["project"]?.stringValue { _ = try await builder.requireProject(name) }
                return await builder.stateJSON()
            },
            RegisteredTool(
                name: "delete_file",
                description: "Delete a file from the project (asks the user first).",
                inputSchema: object(["path": ["type": "string", "minLength": 1], "project": project], required: ["path"]),
                requiresConfirmation: true
            ) { @Sendable args in
                try await builder.deleteFile(project: args["project"]?.stringValue, path: args["path"]?.stringValue ?? "")
                return await builder.stateJSON()
            },
            RegisteredTool(
                name: "check_preview",
                description: "Reload the live preview and report console errors/warnings, the page title and visible text, and for decks the slide count.",
                inputSchema: object(["project": project], required: [])
            ) { @Sendable args in
                _ = try await builder.requireProject(args["project"]?.stringValue)
                return try await builder.reloadAndReport()
            },
            RegisteredTool(
                name: "show_slide",
                description: "Show a slide of the open presentation in the preview (0-based index).",
                inputSchema: object(["index": ["type": "integer", "minimum": 0]], required: ["index"])
            ) { @Sendable args in
                try await builder.showSlide(args["index"]?.intValue ?? 0)
            },
        ]
    }

    // MARK: Settings and presets

    static func settingsTools(_ app: AppModel) -> [RegisteredTool] {
        let parts: JSONValue = ["type": "string", "enum": ["all", "capture", "models"],
                                "description": "capture = mic, screen, camera inset, layout, crop; models = model per task and options"]
        @Sendable func partSet(_ v: JSONValue?) -> PresetParts {
            switch v?.stringValue { case "capture": .capture; case "models": .models; default: .all }
        }
        return [
            RegisteredTool(
                name: "get_settings",
                description: "Get all of Snazzy Pro's settings: models per task, Anthropic/Ollama options, voice and session-record options, the capture setup (mic, screen, inset camera, layout, crop) and saved presets. API keys are never shown.",
                inputSchema: emptySchema
            ) { @Sendable _ in await app.settingsJSON() },
            RegisteredTool(
                name: "update_settings",
                description: "Change app options: voice_auto_send (send voice messages as soon as the user stops talking), record_sessions (keep a session record), effort (Anthropic: low, medium, high, xhigh, max), max_output_tokens. Use set_model for models and the capture tools for devices.",
                inputSchema: object([
                    "voice_auto_send": ["type": "boolean"],
                    "record_sessions": ["type": "boolean"],
                    "effort": ["type": "string", "enum": ["low", "medium", "high", "xhigh", "max"]],
                    "max_output_tokens": ["type": "integer", "minimum": 4000, "maximum": 128000],
                ], required: [])
            ) { @Sendable args in
                await app.updateOptions(voiceAutoSend: args["voice_auto_send"]?.boolValue, recordSessions: args["record_sessions"]?.boolValue,
                                        effort: args["effort"]?.stringValue, maxOutputTokens: args["max_output_tokens"]?.intValue)
            },
            RegisteredTool(
                name: "list_presets",
                description: "List saved settings presets with what each contains, and which one is active.",
                inputSchema: emptySchema
            ) { @Sendable _ in await app.presets.listJSON() },
            RegisteredTool(
                name: "save_preset",
                description: "Save the current settings as a named preset (replaces a preset with the same name). include: all (default), capture, or models.",
                inputSchema: object([
                    "name": ["type": "string", "minLength": 1, "maxLength": 80],
                    "notes": ["type": "string", "description": "What this preset is for"],
                    "include": parts,
                ], required: ["name"])
            ) { @Sendable args in
                let p = try await app.presets.save(name: args["name"]?.stringValue ?? "", notes: args["notes"]?.stringValue ?? "",
                                                   parts: partSet(args["include"]))
                return PresetController.summary(p)
            },
            RegisteredTool(
                name: "load_preset",
                description: "Load a saved preset by name (partial names work). apply: all (default), capture, or models. Returns the resulting settings.",
                inputSchema: object(["name": ["type": "string", "minLength": 1], "apply": parts], required: ["name"])
            ) { @Sendable args in
                try await app.presets.load(args["name"]?.stringValue ?? "", parts: partSet(args["apply"]))
                return await app.settingsJSON()
            },
            RegisteredTool(
                name: "delete_preset",
                description: "Delete a saved preset (asks the user first).",
                inputSchema: object(["name": ["type": "string", "minLength": 1]], required: ["name"]),
                requiresConfirmation: true
            ) { @Sendable args in
                try await app.presets.delete(args["name"]?.stringValue ?? "")
                return await app.presets.listJSON()
            },
        ]
    }

    // MARK: Models

    static func modelTools(_ app: AppModel) -> [RegisteredTool] {
        let tasks: [JSONValue] = AssistantTask.allCases.map { .string($0.rawValue) }
        let providers: [JSONValue] = ProviderKind.allCases.map { .string($0.rawValue) }
        return [
            RegisteredTool(
                name: "list_models",
                description: "List available models per provider (local Ollama models and Anthropic models), whether each runs locally, and which model each task (planning, writing, building, quickCommands) uses.",
                inputSchema: emptySchema
            ) { @Sendable _ in await app.modelsJSON() },
            RegisteredTool(
                name: "set_model",
                description: "Choose the provider and model for a task: planning, writing, building (the builder agent) or quickCommands. Takes effect from the next message. Local (ollama) models keep everything on this Mac.",
                inputSchema: object([
                    "task": ["type": "string", "enum": .array(tasks)],
                    "provider": ["type": "string", "enum": .array(providers)],
                    "model": ["type": "string", "minLength": 1],
                    "make_active": ["type": "boolean", "description": "Also switch the chat to this task"],
                ], required: ["task", "provider", "model"])
            ) { @Sendable args in
                try await app.setModel(task: args["task"]?.stringValue ?? "", provider: args["provider"]?.stringValue ?? "",
                                       model: args["model"]?.stringValue ?? "", makeActive: args["make_active"]?.boolValue ?? false)
            },
        ]
    }

    private static func resolveDeviceID(_ query: String?, capture: CaptureController) throws -> String? {
        guard let query, !query.isEmpty else { return nil }
        let all = capture.catalog.iosDevices + capture.catalog.cameras
        guard let device = DeviceMatcher.match(query, in: all, id: \.id, name: \.name) else {
            throw CaptureActionError(message: "No camera matches “\(query)”. Cameras: " + all.map(\.name).joined(separator: ", "))
        }
        return device.id
    }

    static let emptySchema: JSONValue = ["type": "object", "properties": [:], "additionalProperties": false]

    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }
}
