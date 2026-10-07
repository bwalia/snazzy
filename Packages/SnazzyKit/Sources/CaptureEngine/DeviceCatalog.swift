import AppKit
import AVFoundation
import CoreMediaIO
import Observation
@preconcurrency import ScreenCaptureKit
import SnazzyCore

/// Discovers microphones, cameras, iOS devices (USB), displays and windows,
/// and keeps the lists current as devices come and go.
@MainActor @Observable
public final class DeviceCatalog {
    public private(set) var microphones: [MicrophoneInfo] = []
    public private(set) var cameras: [CaptureDeviceInfo] = []
    public private(set) var iosDevices: [CaptureDeviceInfo] = []
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var windows: [WindowInfo] = []
    public private(set) var screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    /// Bumped on every device connect/disconnect.
    public private(set) var changeCount = 0
    /// Called after the device lists change (connect/disconnect).
    @ObservationIgnored public var onDevicesChanged: (() -> Void)?

    private let diagnostics: Diagnostics
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
        Self.allowScreenCaptureDevices()
        refreshAVDevices()
        refreshDisplaysFromScreens()
        observe()
    }

    /// iOS device screens are hidden from AVFoundation unless the process opts in.
    /// After this they appear asynchronously (up to ~30 s).
    public static func allowScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    // MARK: Refresh

    public func refresh() async {
        refreshAVDevices()
        await refreshScreenContent()
    }

    public func refreshAVDevices() {
        let audio = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let defaultMic = AVCaptureDevice.default(for: .audio)?.uniqueID
        microphones = audio.map {
            MicrophoneInfo(id: $0.uniqueID, name: $0.localizedName, manufacturer: $0.manufacturer,
                           isDefault: $0.uniqueID == defaultMic)
        }

        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
        cameras = video.map(Self.info)

        iosDevices = Self.iosCaptureDevices().map(Self.info)
    }

    static func iosCaptureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
            .devices.filter { $0.modelID == "iOS Device" }
    }

    static func info(_ d: AVCaptureDevice) -> CaptureDeviceInfo {
        let kind = DeviceKind.detect(name: d.localizedName, modelID: d.modelID)
        let transport: String =
            if d.modelID == "iOS Device" { "USB (screen)" }
            else if d.deviceType == .continuityCamera { "Continuity Camera" }
            else if d.deviceType == .builtInWideAngleCamera { "Built-in" }
            else { "External" }
        return CaptureDeviceInfo(id: d.uniqueID, name: d.localizedName, modelID: d.modelID,
                                 manufacturer: d.manufacturer, kind: kind, transport: transport)
    }

    /// Displays from AppKit; works without screen-recording permission.
    func refreshDisplaysFromScreens() {
        let mainID = CGMainDisplayID()
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return DisplayInfo(id: id, name: screen.localizedName, width: CGDisplayPixelsWide(id),
                               height: CGDisplayPixelsHigh(id), isMain: id == mainID)
        }
    }

    /// Windows need screen-recording permission; without it only displays are listed.
    public func refreshScreenContent() async {
        refreshDisplaysFromScreens()
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        guard screenRecordingAllowed else {
            windows = []
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ownBundle = Bundle.main.bundleIdentifier
            windows = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80 }
                .filter { $0.owningApplication?.bundleIdentifier != ownBundle }
                .compactMap { w in
                    guard let app = w.owningApplication?.applicationName, !app.isEmpty else { return nil }
                    return WindowInfo(id: w.windowID, app: app, title: w.title ?? "",
                                      width: Int(w.frame.width), height: Int(w.frame.height))
                }
        } catch {
            diagnostics.log("Could not list windows: \(error.localizedDescription)", category: "screen", level: .warning)
            windows = []
        }
    }

    /// Shows the system prompt for screen-recording permission (once per app).
    public func requestScreenRecording() {
        screenRecordingAllowed = CGRequestScreenCaptureAccess()
    }

    // MARK: Waiting for devices

    /// Waits for a specific iOS device (or any, if `query` is empty) to appear.
    /// iOS devices can take ~30 s, and longer after another app used them.
    public func waitForIOSDevice(
        matching query: String, timeout: TimeInterval = 45, progress: ((TimeInterval) -> Void)? = nil
    ) async -> CaptureDeviceInfo? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            refreshAVDevices()
            let found = query.isEmpty
                ? iosDevices.first
                : DeviceMatcher.match(query, in: iosDevices, id: \.id, name: \.name)
            if let found { return found }
            progress?(Date().timeIntervalSince(start))
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return nil }
        }
        return nil
    }

    // MARK: Notifications

    private func observe() {
        let nc = NotificationCenter.default
        let connected = nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) {
            [weak self] note in
            let name = (note.object as? AVCaptureDevice)?.localizedName ?? "device"
            MainActor.assumeIsolated { self?.deviceChanged("Connected: \(name)") }
        }
        let disconnected = nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) {
            [weak self] note in
            let name = (note.object as? AVCaptureDevice)?.localizedName ?? "device"
            MainActor.assumeIsolated { self?.deviceChanged("Disconnected: \(name)", level: .warning) }
        }
        let screens = nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDisplaysFromScreens()
                self?.diagnostics.log("Display configuration changed", category: "screen")
            }
        }
        observers = [connected, disconnected, screens]
    }

    private func deviceChanged(_ message: String, level: Diagnostics.Entry.Level = .info) {
        diagnostics.log(message, level: level)
        refreshAVDevices()
        changeCount += 1
        onDevicesChanged?()
    }
}
