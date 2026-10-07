import AppKit
import CoreImage
import CaptureEngine
import Foundation
import Observation
import SnazzyCore

struct CaptureActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The capture actions. Buttons in the Sources panel and the assistant's tools
/// call the same methods here.
@MainActor @Observable
final class CaptureController {
    let catalog: DeviceCatalog
    let feeds: FeedManager
    let diagnostics: Diagnostics
    /// Live capture of the selected display/window (for the recording preview and the recorder).
    let screen: ScreenFeed
    let recorder = Recorder()
    /// Called when a recording starts or finishes (session log).
    @ObservationIgnored var onRecordingEvent: ((String, [String: JSONValue]) -> Void)?
    /// The app's own windows that should appear in a display capture (e.g. the builder's result window).
    @ObservationIgnored var ownWindowsToInclude: () -> [UInt32] = { [] }

    private(set) var setup: CaptureSetup {
        didSet { if setup != oldValue { store.save(setup) } }
    }
    /// The running feed for the selected inset device.
    private(set) var insetFeed: CameraFeed?
    /// Shown while waiting for an iOS device to appear.
    private(set) var searchStatus: String?
    private(set) var micWarning: String?
    private(set) var openPreviewIDs: Set<String> = []

    @ObservationIgnored private let store: CaptureSetupStore
    @ObservationIgnored private var previewWindows: [String: PreviewWindowController] = [:]
    @ObservationIgnored private var compositeWindow: CompositePreviewWindowController?
    @ObservationIgnored private var screenUsers: Set<String> = []
    private(set) var compositePreviewOpen = false

    init(store: CaptureSetupStore = CaptureSetupStore(), diagnostics: Diagnostics = .shared) {
        self.store = store
        self.diagnostics = diagnostics
        self.setup = store.load()
        self.catalog = DeviceCatalog(diagnostics: diagnostics)
        self.feeds = FeedManager(diagnostics: diagnostics)
        self.screen = ScreenFeed(diagnostics: diagnostics)
        catalog.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        checkMic()
    }

    /// Starts the feed for a saved inset device (call once the UI is up).
    func restoreInsetFeed() {
        guard insetFeed == nil, let selection = setup.insetDevice else { return }
        let info = (catalog.cameras + catalog.iosDevices).first { $0.id == selection.uniqueID }
            ?? CaptureDeviceInfo(id: selection.uniqueID, name: selection.name, modelID: selection.kind == .camera ? "" : "iOS Device",
                                 manufacturer: "", kind: selection.kind, transport: "")
        insetFeed = feeds.acquire(info)
    }

    // MARK: Microphone

    @discardableResult
    func selectMic(_ query: String) throws -> MicrophoneInfo {
        catalog.refreshAVDevices()
        guard let mic = DeviceMatcher.match(query, in: catalog.microphones, id: \.id, name: \.name) else {
            throw CaptureActionError(message: "No microphone matches “\(query)”. Available: "
                + catalog.microphones.map(\.name).joined(separator: ", "))
        }
        setup.mic = MicSelection(uniqueID: mic.id, name: mic.name)
        micWarning = nil
        diagnostics.log("Microphone: \(mic.name)")
        return mic
    }

    /// USB mics change ID when moved to another port: reselect by name and warn.
    private func checkMic() {
        guard let selected = setup.mic else { micWarning = nil; return }
        if catalog.microphones.contains(where: { $0.id == selected.uniqueID }) {
            micWarning = nil
        } else if let same = catalog.microphones.first(where: { $0.name == selected.name }) {
            setup.mic = MicSelection(uniqueID: same.id, name: same.name)
            micWarning = "“\(same.name)” came back with a different ID (another USB port?). Reselected it."
            diagnostics.log("Microphone \(same.name) reselected by name (ID changed)", level: .warning)
        } else {
            micWarning = "“\(selected.name)” is disconnected."
            diagnostics.log("Microphone \(selected.name) disconnected", level: .warning)
        }
    }

    private func devicesChanged() {
        checkMic()
    }

    // MARK: Capture source

    func selectDisplay(_ query: String) throws -> DisplayInfo {
        catalog.refreshAVDevices()
        let display: DisplayInfo?
        if let n = Int(query), let byID = catalog.displays.first(where: { $0.id == UInt32(n) }) {
            display = byID
        } else if ["main", "primary", "built-in", "builtin"].contains(query.lowercased()) {
            display = catalog.displays.first(where: \.isMain)
        } else {
            display = DeviceMatcher.match(query, in: catalog.displays, id: { String($0.id) }, name: \.name)
        }
        guard let display else {
            throw CaptureActionError(message: "No display matches “\(query)”. Available: "
                + catalog.displays.map { "\($0.name) (id \($0.id))" }.joined(separator: ", "))
        }
        setup.source = .display(id: display.id, name: display.name)
        diagnostics.log("Capture source: display \(display.name)")
        sourceChanged()
        return display
    }

    func selectWindow(_ query: String) async throws -> WindowInfo {
        await catalog.refreshScreenContent()
        guard catalog.screenRecordingAllowed else {
            throw CaptureActionError(message: "Screen recording permission is needed to list windows. Ask the user to allow it in the Sources panel.")
        }
        let window: WindowInfo?
        if let n = UInt32(query) {
            window = catalog.windows.first { $0.id == n }
        } else {
            window = DeviceMatcher.match(query, in: catalog.windows, id: { String($0.id) }, name: { "\($0.app) \($0.title)" })
        }
        guard let window else {
            throw CaptureActionError(message: "No window matches “\(query)”. Open windows: "
                + catalog.windows.prefix(20).map { "\($0.app): \($0.title) (id \($0.id))" }.joined(separator: "; "))
        }
        setup.source = .window(id: window.id, app: window.app, title: window.title)
        diagnostics.log("Capture source: window \(window.app) – \(window.title)")
        sourceChanged()
        return window
    }

    func selectSlidesSource() {
        setup.source = .slides
        diagnostics.log("Capture source: slides")
        sourceChanged()
    }

    // MARK: Inset device

    /// Selects the inset camera by name or ID; "none" removes it. iOS devices
    /// can take up to ~30 s to appear, so this waits for them.
    @discardableResult
    func selectInsetDevice(_ query: String) async throws -> CaptureDeviceInfo? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty || ["none", "off", "no inset"].contains(q.lowercased()) {
            setInsetDevice(nil)
            return nil
        }
        catalog.refreshAVDevices()
        let all = catalog.iosDevices + catalog.cameras
        var device = DeviceMatcher.match(q, in: all, id: \.id, name: \.name)
        let wantsIOS = ["ipad", "iphone", "ios"].contains { q.lowercased().contains($0) }
        if device == nil || (wantsIOS && device?.kind == .camera) {
            // "iPhone" can also match the Continuity "iPhone Camera"; prefer the
            // USB screen device when it appears.
            searchStatus = "Looking for \(q)…"
            defer { searchStatus = nil }
            let filter = wantsIOS && !q.lowercased().contains(" ") ? "" : q
            let found = await catalog.waitForIOSDevice(matching: filter, timeout: device == nil ? 45 : 8) { [weak self] elapsed in
                self?.searchStatus = "Waiting for \(q) to appear… \(Int(elapsed))s (connect by USB, unlock, tap Trust)"
            }
            let kindWanted: DeviceKind? = q.lowercased().contains("iphone") ? .iPhone : q.lowercased().contains("ipad") ? .iPad : nil
            if let found, kindWanted == nil || found.kind == kindWanted {
                device = found
            } else if device == nil {
                throw CaptureActionError(message: "Couldn't find “\(q)”. Cameras: "
                    + all.map(\.name).joined(separator: ", ")
                    + ". For an iPad/iPhone: connect it by USB, unlock it and tap Trust.")
            }
        }
        setInsetDevice(device)
        return device
    }

    func setInsetDevice(_ device: CaptureDeviceInfo?) {
        // The inset holds its own reference to the feed; previews hold theirs.
        if let feed = insetFeed, feed.device.id != device?.id {
            feeds.release(feed.device.id)
            insetFeed = nil
        }
        guard let device else {
            setup.insetDevice = nil
            diagnostics.log("Inset: none")
            return
        }
        setup.insetDevice = InsetDeviceSelection(uniqueID: device.id, name: device.name, kind: device.kind)
        if insetFeed?.device.id != device.id { insetFeed = feeds.acquire(device) }
        diagnostics.log("Inset device: \(device.name)")
    }

    // MARK: Inset layout and crop

    func profile(for deviceID: String, kind: DeviceKind) -> DeviceProfile {
        setup.profile(for: deviceID, kind: kind)
    }

    var insetProfile: DeviceProfile? {
        setup.insetDevice.map { setup.profile(for: $0.uniqueID, kind: $0.kind) }
    }

    func setProfile(_ profile: DeviceProfile, for deviceID: String) {
        var p = profile
        p.crop = p.crop.normalized
        setup.profiles[deviceID] = p
        previewWindows[deviceID]?.contentChanged()
        recorder.update(spec: compositeSpec)
    }

    func setLayout(_ layout: InsetLayout) {
        setup.layout = layout.normalized
        recorder.update(spec: compositeSpec)
    }

    /// Applies set_inset changes to the layout and the inset device's profile.
    func updateInset(_ changes: InsetChanges, deviceID: String? = nil) throws {
        var layout = setup.layout
        guard let target = deviceID.flatMap({ id in (catalog.cameras + catalog.iosDevices).first { $0.id == id } })
            .map({ InsetDeviceSelection(uniqueID: $0.id, name: $0.name, kind: $0.kind) }) ?? setup.insetDevice
        else {
            // Layout-only changes don't need a device.
            var dummy = DeviceProfile.defaults(for: .camera)
            changes.apply(layout: &layout, profile: &dummy)
            setup.layout = layout
            return
        }
        var profile = setup.profile(for: target.uniqueID, kind: target.kind)
        changes.apply(layout: &layout, profile: &profile)
        setup.layout = layout
        setProfile(profile, for: target.uniqueID)
        recorder.update(spec: compositeSpec)
    }

    func resetProfile(for device: InsetDeviceSelection) {
        setProfile(.defaults(for: device.kind), for: device.uniqueID)
    }

    // MARK: Previews

    /// Opens a floating preview for a device (default: the inset device).
    func openPreview(deviceID: String? = nil) throws {
        let id = deviceID ?? setup.insetDevice?.uniqueID
        guard let id else { throw CaptureActionError(message: "No inset device selected. Select one first.") }
        if let existing = previewWindows[id] {
            existing.show()
            return
        }
        let info = (catalog.cameras + catalog.iosDevices).first { $0.id == id }
            ?? insetFeed.map(\.device).flatMap { $0.id == id ? $0 : nil }
        guard let info else { throw CaptureActionError(message: "Device \(id) isn't connected.") }
        let feed = feeds.acquire(info)
        let controller = PreviewWindowController(feed: feed, capture: self)
        controller.onClose = { [weak self] in self?.previewClosed(id) }
        previewWindows[id] = controller
        openPreviewIDs.insert(id)
        controller.show()
        diagnostics.log("Preview opened: \(info.name)", category: "preview")
    }

    func closePreview(deviceID: String? = nil) {
        let ids = deviceID.map { [$0] } ?? Array(previewWindows.keys)
        for id in ids { previewWindows[id]?.close() }
    }

    private func previewClosed(_ id: String) {
        guard previewWindows.removeValue(forKey: id) != nil else { return }
        openPreviewIDs.remove(id)
        feeds.release(id)
        diagnostics.log("Preview closed", category: "preview")
    }

    /// Windows that must never appear in a recording (used by the recorder, phase 4).
    var excludedWindowNumbers: [Int] {
        previewWindows.values.compactMap(\.windowNumber) + [compositeWindow?.windowNumber].compactMap { $0 }
    }

    // MARK: Screen and recording preview

    /// The ScreenCaptureKit source for the current selection (slides come in phase 6).
    var screenSource: ScreenFeed.Source? {
        switch setup.source {
        case .display(let id, _)?: .display(id)
        case .window(let id, _, _)?: .window(id)
        default: nil
        }
    }

    /// Someone (the Sources panel, the floating preview, the recorder) needs the screen feed.
    func useScreen(_ user: String, _ active: Bool) {
        if active { screenUsers.insert(user) } else { screenUsers.remove(user) }
        Task { await updateScreenFeed() }
    }

    private func sourceChanged() {
        Task { await updateScreenFeed() }
    }

    func updateScreenFeed() async {
        guard !screenUsers.isEmpty, let source = screenSource else {
            await screen.stop()
            return
        }
        await screen.start(source, includingOwnWindows: ownWindowsToInclude())
    }

    var compositeSpec: CompositeSpec {
        let profile = setup.insetDevice.map { setup.profile(for: $0.uniqueID, kind: $0.kind) } ?? .defaults(for: .camera)
        return CompositeSpec(layout: setup.layout, profile: profile)
    }

    /// The current recorded picture: screen + inset.
    func compositeFrame() -> (image: CIImage, sequence: Int)? {
        let screenFrame = screen.receiver.latest
        let cameraFrame = insetFeed?.receiver.latest
        guard screenFrame != nil || cameraFrame != nil else { return nil }
        let image = Compositor.compose(screen: screenFrame?.image, camera: cameraFrame?.image, spec: compositeSpec)
        return (image, (screenFrame?.sequence ?? 0) &* 1_000_003 &+ (cameraFrame?.sequence ?? 0))
    }

    func openCompositePreview() {
        if compositeWindow == nil {
            let controller = CompositePreviewWindowController(capture: self)
            controller.onClose = { [weak self] in
                self?.compositeWindow = nil
                self?.compositePreviewOpen = false
                self?.useScreen("composite-window", false)
            }
            compositeWindow = controller
        }
        compositePreviewOpen = true
        useScreen("composite-window", true)
        compositeWindow?.show()
        diagnostics.log("Recording preview opened", category: "preview")
    }

    func closeCompositePreview() {
        compositeWindow?.close()
    }

    // MARK: Recording

    /// Starts recording the selected screen, the inset camera and the mic.
    func startRecording(countdown: Int = 3) async throws {
        guard screenSource != nil else {
            throw CaptureActionError(message: setup.source == .slides
                ? "Recording slides arrives in phase 6. Choose a display or window for now."
                : "Choose a display or window to record first.")
        }
        restoreInsetFeed()
        useScreen("recorder", true)
        await updateScreenFeed()
        // Give the first screen frame a moment to arrive.
        for _ in 0..<20 where screen.receiver.latest == nil { try? await Task.sleep(for: .milliseconds(100)) }
        do {
            try await recorder.start(screen: screen, camera: insetFeed, micID: setup.mic?.uniqueID,
                                     spec: compositeSpec, countdown: countdown)
            if recorder.state == .recording {
                onRecordingEvent?("recording_started", ["mic": .string(setup.mic?.name ?? "default"),
                                                        "camera": .string(setup.insetDevice?.name ?? "none")])
            } else {
                useScreen("recorder", false)
            }
        } catch {
            useScreen("recorder", false)
            throw error
        }
    }

    func pauseRecording() { recorder.pause() }
    func resumeRecording() { recorder.resume() }

    @discardableResult
    func stopRecording() async -> RecordingResult? {
        let result = await recorder.stop()
        useScreen("recorder", false)
        if let result {
            onRecordingEvent?("recording_saved", ["file": .string(result.composite.path), "seconds": .number(result.duration)])
        }
        return result
    }

    func recordingJSON() -> JSONValue {
        var state: [String: JSONValue] = ["elapsed_seconds": .number((recorder.elapsed * 10).rounded() / 10)]
        switch recorder.state {
        case .idle: state["state"] = "idle"
        case .countdown(let n): state["state"] = .string("countdown \(n)")
        case .recording: state["state"] = "recording"
        case .paused: state["state"] = "paused"
        case .finishing: state["state"] = "saving"
        case .failed(let m): state["state"] = "failed"; state["error"] = .string(m)
        }
        if let warning = recorder.warning { state["warning"] = .string(warning) }
        if let last = recorder.lastResult {
            state["last_recording"] = [
                "file": .string(last.composite.path), "raw_tracks": .string(last.rawFolder.path),
                "seconds": .number((last.duration * 10).rounded() / 10),
                "camera_freezes": .number(Double(last.freezes.count)), "dropped_frames": .number(Double(last.droppedFrames)),
            ]
        }
        return .object(state)
    }

    // MARK: State for the assistant

    func devicesJSON() async -> JSONValue {
        await catalog.refresh()
        let selectedMic = setup.mic?.uniqueID
        return [
            "microphones": .array(catalog.microphones.map {
                ["id": .string($0.id), "name": .string($0.name), "selected": .bool($0.id == selectedMic), "system_default": .bool($0.isDefault)]
            }),
            "cameras": .array(catalog.cameras.map(deviceJSON)),
            "ios_devices": .array(catalog.iosDevices.map(deviceJSON)),
            "displays": .array(catalog.displays.map {
                ["id": .number(Double($0.id)), "name": .string($0.name), "resolution": .string("\($0.width)x\($0.height)"), "main": .bool($0.isMain)]
            }),
            "windows": catalog.screenRecordingAllowed
                ? .array(catalog.windows.prefix(30).map {
                    ["id": .number(Double($0.id)), "app": .string($0.app), "title": .string($0.title)]
                })
                : "unavailable: screen recording permission not granted",
            "note": "iPad/iPhone screens can take up to 30 s to appear after connecting.",
        ]
    }

    private func deviceJSON(_ d: CaptureDeviceInfo) -> JSONValue {
        ["id": .string(d.id), "name": .string(d.name), "kind": .string(d.kind.rawValue), "connection": .string(d.transport),
         "selected_as_inset": .bool(d.id == setup.insetDevice?.uniqueID)]
    }

    func stateJSON() -> JSONValue {
        var state: [String: JSONValue] = [
            "microphone": setup.mic.map { ["name": .string($0.name), "id": .string($0.uniqueID)] } ?? .null,
            "capture_source": sourceJSON,
            "inset_layout": [
                "position": .string(setup.layout.corner.rawValue),
                "size": .number(setup.layout.size),
                "border_width": .number(setup.layout.borderWidth),
                "corner_radius": .number(setup.layout.cornerRadius),
            ],
            "open_previews": .array(openPreviewIDs.sorted().map { .string($0) }),
            "recording_preview_open": .bool(compositePreviewOpen),
            "screen_capture": .string(screen.state.description),
        ]
        if let warning = micWarning { state["microphone_warning"] = .string(warning) }
        if let inset = setup.insetDevice {
            let p = setup.profile(for: inset.uniqueID, kind: inset.kind)
            var device: [String: JSONValue] = [
                "name": .string(inset.name), "id": .string(inset.uniqueID), "kind": .string(inset.kind.rawValue),
                "aspect": p.crop.aspect.map { .number(($0 * 1000).rounded() / 1000) } ?? "fit",
                "zoom": .number(p.crop.zoom), "center_x": .number(p.crop.centerX), "center_y": .number(p.crop.centerY),
                "rotation": .string(p.rotation.rawValue), "video_delay_ms": .number(p.videoDelayMs),
            ]
            if let feed = insetFeed {
                device["status"] = .string(feed.state.description)
                if let s = feed.frameSize { device["frame_size"] = .string("\(Int(s.width))x\(Int(s.height))") }
            }
            state["inset_device"] = .object(device)
        } else {
            state["inset_device"] = .null
        }
        return .object(state)
    }

    private var sourceJSON: JSONValue {
        switch setup.source {
        case .display(let id, let name)?: ["type": "display", "id": .number(Double(id)), "name": .string(name)]
        case .window(let id, let app, let title)?: ["type": "window", "id": .number(Double(id)), "app": .string(app), "title": .string(title)]
        case .slides?: ["type": "slides"]
        case nil: .null
        }
    }
}
