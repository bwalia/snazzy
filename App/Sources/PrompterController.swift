import AppKit
import CaptureEngine
import SnazzyCore
import SwiftUI

/// The camera prompter: a strip of text right under the camera, so you can read
/// your notes or a script while looking at the lens. It floats above other
/// windows and is never recorded, streamed or shown in the live room (own
/// windows are left out of screen capture, and sharingType is .none).
@MainActor @Observable
final class PrompterController {
    var settings: PrompterSettings {
        didSet { save() }
    }
    private(set) var isShown = false
    private(set) var isScrolling = false
    /// How far the text has scrolled, in points.
    var offset: Double = 0
    /// Laid-out text height, reported by the view.
    var contentHeight: Double = 0
    /// Editing the script in place.
    var isEditing = false

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var panel: PrompterPanel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: Date?
    static let settingsKey = "SnazzyPro.prompter.v1"
    static let frameName = "SnazzyProCameraPrompter"

    init(app: AppModel) {
        self.app = app
        settings = UserDefaults.standard.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(PrompterSettings.self, from: $0) } ?? PrompterSettings()
        watchRecording()
        watchSlides()
    }

    var windowNumber: Int? { isShown ? panel?.windowNumber : nil }

    /// What's on the prompter now.
    var text: String {
        switch settings.source {
        case .script:
            return settings.script
        case .notes:
            let b = app.builder
            guard b.isDeckOpen, b.deckSlides.indices.contains(b.currentSlide) else { return "" }
            return b.deckSlides[b.currentSlide].notes
        }
    }

    /// Shown when there's nothing to read.
    var placeholder: String {
        switch settings.source {
        case .script: "Click the pencil to type or paste your script."
        case .notes: app.builder.isDeckOpen
            ? "No speaker notes on this slide."
            : "Open a slide deck to see its speaker notes here, or switch to Script."
        }
    }

    // MARK: Window

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        isShown = true
    }

    func hide() {
        pause()
        isEditing = false
        panel?.orderOut(nil)
        isShown = false
    }

    func toggle() { isShown ? hide() : show() }

    /// Back to the top-centre of the screen with the built-in camera.
    func placeUnderCamera() {
        guard let panel else { return }
        panel.setFrame(Self.defaultFrame(size: panel.frame.size), display: true, animate: true)
    }

    /// To the top-centre of another display (where an external camera usually sits).
    func move(to screen: NSScreen) {
        guard let panel else { return }
        panel.setFrame(Prompter.frameUnderCamera(visible: screen.visibleFrame, width: panel.frame.width, height: panel.frame.height),
                       display: true, animate: true)
    }

    func move(toDisplayNamed name: String) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) else { return false }
        move(to: screen)
        return true
    }

    /// The displays it can go on, for the assistant ("Built-in Retina Display", "DELL U2723QE"…).
    var screenNames: [String] { NSScreen.screens.map(\.localizedName) }

    private func makePanel() -> PrompterPanel {
        let panel = PrompterPanel(
            contentRect: Self.defaultFrame(size: CGSize(width: 680, height: 230)),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 110)
        let host = NSHostingView(rootView: PrompterView().environment(self).environment(app))
        host.sizingOptions = []  // the window keeps its size; the text scrolls inside it
        panel.contentView = host
        // Remembers where the user put it (setting the autosave name restores the
        // saved frame); the first time, it goes under the camera. A saved frame
        // taller than half the screen is a mistake: start again.
        let restored = panel.setFrameUsingName(Self.frameName)
        panel.setFrameAutosaveName(Self.frameName)
        if !restored || panel.frame.height > (panel.screen?.visibleFrame.height ?? 1000) / 2 {
            panel.setFrame(Self.defaultFrame(size: CGSize(width: 680, height: 230)), display: false)
        }
        return panel
    }

    /// The screen with the built-in camera: the one with a notch, else the built-in
    /// display, else the main screen.
    static func cameraScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built-in") }
            ?? NSScreen.main
    }

    static func defaultFrame(size: CGSize) -> CGRect {
        guard let visible = cameraScreen()?.visibleFrame else { return CGRect(origin: .zero, size: size) }
        return Prompter.frameUnderCamera(visible: visible, width: size.width, height: size.height)
    }

    // MARK: Scrolling

    var pointsPerSecond: Double {
        Prompter.pointsPerSecond(text: text, contentHeight: contentHeight, wordsPerMinute: settings.wordsPerMinute)
    }

    func start() {
        guard !text.isEmpty else { return }
        if offset >= contentHeight - 1 { offset = 0 }
        isScrolling = true
        lastTick = nil
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        isScrolling = false
        timer?.invalidate()
        timer = nil
    }

    func toggleScrolling() { isScrolling ? pause() : start() }

    func restart() {
        offset = 0
        lastTick = nil
    }

    /// Moves the text by hand (dragging or the arrow buttons).
    func nudge(by points: Double) {
        offset = min(max(0, offset + points), max(0, contentHeight))
    }

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        guard let last = lastTick else { return }
        offset += pointsPerSecond * now.timeIntervalSince(last)
        if offset >= contentHeight { offset = contentHeight; pause() }
    }

    // MARK: Following the recording and slides

    private func watchRecording() {
        withObservationTracking { _ = app.capture.recorder.state } onChange: { [weak self] in
            Task { @MainActor in
                self?.recordingChanged()
                self?.watchRecording()
            }
        }
    }

    private func recordingChanged() {
        guard isShown, settings.followsRecording else { return }
        switch app.capture.recorder.state {
        case .recording: if !isScrolling { start() }
        case .paused, .finishing, .idle, .failed: pause()
        case .countdown: restart()
        }
    }

    private func watchSlides() {
        withObservationTracking { _ = app.builder.currentSlide } onChange: { [weak self] in
            Task { @MainActor in
                // A new slide's notes start from the top.
                if self?.settings.source == .notes { self?.restart() }
                self?.watchSlides()
            }
        }
    }

    // MARK: Assistant

    func stateJSON() -> JSONValue {
        [
            "visible": .bool(isShown),
            "scrolling": .bool(isScrolling),
            "source": .string(settings.source.rawValue),
            "words": .number(Double(Prompter.wordCount(text))),
            "words_per_minute": .number(settings.wordsPerMinute),
            "font_size": .number(settings.fontSize),
            "follows_recording": .bool(settings.followsRecording),
            "display": .string(panel?.screen?.localizedName ?? ""),
            "displays": .array(screenNames.map { .string($0) }),
        ]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }
}

/// A panel that can take keyboard focus (for editing the script) without
/// activating the app over what you're presenting.
final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
