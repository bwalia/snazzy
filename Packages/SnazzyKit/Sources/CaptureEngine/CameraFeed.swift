@preconcurrency import AVFoundation
import Foundation
import Observation
import SnazzyCore

/// One live camera or iOS-device feed: a capture session configured once,
/// with stall detection, restart and reconnect handling.
@MainActor @Observable
public final class CameraFeed {
    public enum State: Equatable, Sendable {
        case idle
        case waitingForDevice(seconds: Int)
        case starting
        case live
        /// Running, but no first frame yet after a few seconds.
        case noFrames(seconds: Int)
        case stalled(seconds: Int)
        case disconnected
        case failed(String)

        public var description: String {
            switch self {
            case .idle: "Off"
            case .waitingForDevice(let s): "Waiting for device… \(s)s"
            case .starting: "Starting…"
            case .live: "Live"
            case .noFrames(let s): "No video yet (\(s)s). Is the device awake, unlocked and nearby?"
            case .stalled(let s): "No new frames for \(s)s"
            case .disconnected: "Disconnected: waiting for it to come back"
            case .failed(let m): m
            }
        }
    }

    public struct Freeze: Hashable, Sendable {
        public var start: Date
        public var duration: TimeInterval
    }

    public let device: CaptureDeviceInfo
    public private(set) var state: State = .idle
    public private(set) var frameSize: CGSize?
    public private(set) var framesPerSecond: Double = 0
    public private(set) var droppedFrames = 0
    /// Periods with no frames (> 2 s), for the timeline.
    public private(set) var freezes: [Freeze] = []

    public let receiver = FrameReceiver()

    /// Gap after which the feed counts as stalled.
    public static let stallThreshold: TimeInterval = 2
    private static let restartAfter: TimeInterval = 5
    private static let restartInterval: TimeInterval = 10

    @ObservationIgnored private let box = SessionBox()
    @ObservationIgnored private let diagnostics: Diagnostics
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var stallStart: Date?
    @ObservationIgnored private var lastRestart = Date.distantPast
    @ObservationIgnored private var lastCount = 0
    @ObservationIgnored private var lastCountTime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var runningSince: Date?

    public init(device: CaptureDeviceInfo, diagnostics: Diagnostics = .shared) {
        self.device = device
        self.diagnostics = diagnostics
    }

    public var isIOSDevice: Bool { device.kind != .camera }

    // MARK: Start / stop

    public func start() {
        guard !wanted else { return }
        wanted = true
        observe()
        startTask = Task { await self.startSession() }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    public func stop() {
        wanted = false
        startTask?.cancel()
        watchdog?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let box = box
        Task.detached { box.teardown() }
        state = .idle
        diagnostics.log("Stopped feed: \(device.name)")
    }

    private func startSession() async {
        guard await Self.ensureCameraAccess() else {
            state = .failed("Camera access is off. Allow Snazzy Pro in System Settings → Privacy & Security → Camera.")
            diagnostics.log("Camera access denied", level: .error)
            return
        }
        guard let avDevice = await findDevice() else {
            if wanted {
                state = .failed("\(device.name) not found. Connect it by USB, unlock it and tap Trust.")
                diagnostics.log("\(device.name) did not appear", level: .error)
            }
            return
        }
        state = .starting
        do {
            try box.configure(device: avDevice, receiver: receiver)
        } catch {
            state = .failed(error.localizedDescription)
            diagnostics.log("Could not open \(device.name): \(error.localizedDescription)", level: .error)
            return
        }
        observeSession()
        let box = box
        await Task.detached { box.startRunning() }.value
        runningSince = Date()
        diagnostics.log("Started feed: \(device.name)")
    }

    /// The device by ID; iOS devices may take a while to appear (or reappear).
    private func findDevice() async -> AVCaptureDevice? {
        if let d = AVCaptureDevice(uniqueID: device.id) { return d }
        guard isIOSDevice else { return nil }
        DeviceCatalog.allowScreenCaptureDevices()
        let start = Date()
        while wanted, Date().timeIntervalSince(start) < 45 {
            state = .waitingForDevice(seconds: Int(Date().timeIntervalSince(start)))
            if let d = AVCaptureDevice(uniqueID: device.id)
                ?? DeviceCatalog.iosCaptureDevices().first(where: { $0.localizedName == device.name })
            {
                return d
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    static func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func restart(reason: String) {
        guard wanted else { return }
        lastRestart = Date()
        diagnostics.log("Restarting \(device.name): \(reason)", level: .warning)
        let box = box
        startTask?.cancel()
        startTask = Task {
            await Task.detached { box.teardown() }.value
            await self.startSession()
        }
    }

    // MARK: Watchdog

    private func tick() {
        let stats = receiver.snapshot
        let now = ProcessInfo.processInfo.systemUptime
        droppedFrames = stats.dropped
        if let size = stats.size, size != frameSize { frameSize = size }

        let elapsed = now - lastCountTime
        if elapsed >= 1 {
            framesPerSecond = Double(stats.frames - lastCount) / elapsed
            lastCount = stats.frames
            lastCountTime = now
        }

        guard let last = stats.lastFrameUptime else {
            // Never had a frame: say so instead of "Starting…" forever, and retry now and then.
            guard let since = runningSince else { return }
            let waited = Date().timeIntervalSince(since)
            if waited > 5 {
                if case .noFrames = state {} else {
                    diagnostics.log("No video from \(device.name) after \(Int(waited))s", category: "stall", level: .warning)
                }
                state = .noFrames(seconds: Int(waited))
                if waited > 15, Date().timeIntervalSince(lastRestart) > 20 {
                    restart(reason: "no video after \(Int(waited))s")
                    state = .noFrames(seconds: Int(waited))
                }
            }
            return
        }
        let gap = now - last
        switch state {
        case .starting, .live, .noFrames:
            if gap > Self.stallThreshold {
                stallStart = Date().addingTimeInterval(-gap)
                state = .stalled(seconds: Int(gap))
                let hint = isIOSDevice ? " (the device sends frames only when its screen changes)" : ""
                diagnostics.log("Stall: no frames from \(device.name) for \(Int(gap))s\(hint)", category: "stall", level: .warning)
            } else if state != .live {
                state = .live
            }
        case .stalled:
            if gap < Self.stallThreshold {
                if let since = stallStart {
                    let duration = Date().timeIntervalSince(since) - gap
                    freezes.append(Freeze(start: since, duration: duration))
                    diagnostics.log(String(format: "Resumed: %@ after %.1fs", device.name, duration), category: "stall")
                }
                stallStart = nil
                state = .live
            } else {
                state = .stalled(seconds: Int(gap))
                if gap > Self.restartAfter, Date().timeIntervalSince(lastRestart) > Self.restartInterval {
                    restart(reason: "no frames for \(Int(gap))s")
                    // Keep showing the stall; frames resuming clears it.
                    state = .stalled(seconds: Int(gap))
                }
            }
        default:
            break
        }
    }

    // MARK: Notifications

    private func observe() {
        let nc = NotificationCenter.default
        let id = device.id, name = device.name, ios = isIOSDevice
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) {
            [weak self] note in
            guard (note.object as? AVCaptureDevice)?.uniqueID == id else { return }
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                self.state = .disconnected
                self.stallStart = self.stallStart ?? Date()
                self.diagnostics.log("\(name) disconnected; holding the last frame", level: .warning)
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let d = note.object as? AVCaptureDevice, d.uniqueID == id || (ios && d.localizedName == name) else { return }
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                if case .disconnected = self.state {
                    self.state = .stalled(seconds: 0)
                    self.restart(reason: "reconnected")
                }
            }
        })
    }

    private func observeSession() {
        guard let session = box.session else { return }
        let name = device.name
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "unknown"
            MainActor.assumeIsolated {
                self?.diagnostics.log("Session error (\(name)): \(error)", level: .error)
                self?.restart(reason: "session error")
            }
        })
    }
}

/// Owns the AVCaptureSession; touched from the main actor and a background
/// task (startRunning blocks), never concurrently.
final class SessionBox: @unchecked Sendable {
    private(set) var session: AVCaptureSession?
    private let lock = NSLock()

    struct ConfigError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Configures everything before the session starts: outputs are never
    /// added to a running session (that can interrupt it).
    func configure(device: AVCaptureDevice, receiver: FrameReceiver) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw ConfigError(message: "Cannot use \(device.localizedName)") }
        // Muxed iOS devices also have audio ports; connect video only.
        session.addInputWithNoConnections(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(receiver, queue: receiver.queue)
        guard session.canAddOutput(output) else { throw ConfigError(message: "Cannot read video from \(device.localizedName)") }
        session.addOutputWithNoConnections(output)

        let ports = input.ports.filter { $0.mediaType == .video }
        let connection = AVCaptureConnection(inputPorts: ports, output: output)
        guard !ports.isEmpty, session.canAddConnection(connection) else {
            throw ConfigError(message: "\(device.localizedName) has no usable video")
        }
        session.addConnection(connection)
        lock.withLock { self.session = session }
    }

    func startRunning() {
        lock.withLock { session }?.startRunning()
    }

    func teardown() {
        let s = lock.withLock { () -> AVCaptureSession? in
            defer { session = nil }
            return session
        }
        s?.stopRunning()
    }
}

/// Shares one feed per device between previews (and later the recorder).
@MainActor @Observable
public final class FeedManager {
    public private(set) var feeds: [String: CameraFeed] = [:]
    @ObservationIgnored private var refs: [String: Int] = [:]
    @ObservationIgnored private let diagnostics: Diagnostics

    public init(diagnostics: Diagnostics = .shared) { self.diagnostics = diagnostics }

    public func acquire(_ device: CaptureDeviceInfo) -> CameraFeed {
        refs[device.id, default: 0] += 1
        if let feed = feeds[device.id] { return feed }
        let feed = CameraFeed(device: device, diagnostics: diagnostics)
        feeds[device.id] = feed
        feed.start()
        return feed
    }

    public func release(_ deviceID: String) {
        guard let count = refs[deviceID] else { return }
        if count <= 1 {
            refs[deviceID] = nil
            feeds.removeValue(forKey: deviceID)?.stop()
        } else {
            refs[deviceID] = count - 1
        }
    }
}
