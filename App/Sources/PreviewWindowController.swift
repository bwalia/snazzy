import AppKit
import CaptureEngine
import SnazzyCore
import SwiftUI

/// A floating, resizable preview of one device's inset region. It floats above
/// other windows and is kept out of screen recordings (sharingType = .none, and
/// the recorder excludes it from its content filter).
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    let feed: CameraFeed
    private let panel: NSPanel
    private unowned let capture: CaptureController
    var onClose: (() -> Void)?
    private var aspectTimer: Timer?

    var windowNumber: Int? { panel.isVisible ? panel.windowNumber : nil }

    init(feed: CameraFeed, capture: CaptureController) {
        self.feed = feed
        self.capture = capture
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        panel.title = "\(feed.device.name): inset preview"
        panel.level = .floating
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: InsetPreviewContent(feed: feed).environment(capture))
        panel.minSize = NSSize(width: 200, height: 120)
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 20, y: vf.minY + 20))
        }
        // The picture size is only known once frames arrive (and changes if
        // the device rotates): keep the window's shape in step.
        aspectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.contentChanged() }
        }
    }

    func show() {
        contentChanged()
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }

    /// Matches the window's aspect ratio to the inset content.
    func contentChanged() {
        guard let raw = feed.frameSize else { return }
        let profile = capture.profile(for: feed.device.id, kind: feed.device.kind)
        let size = InsetGeometry.contentSize(raw: raw, profile: profile)
        guard size.width > 0, size.height > 0 else { return }
        panel.contentAspectRatio = size
        let content = panel.contentRect(forFrameRect: panel.frame)
        let height = (content.width * size.height / size.width).rounded()
        if abs(height - content.height) > 1 {
            let rect = NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height)
            panel.setFrame(panel.frameRect(forContentRect: rect), display: true, animate: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        aspectTimer?.invalidate()
        aspectTimer = nil
        onClose?()
    }
}
