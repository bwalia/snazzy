import AppKit
import CaptureEngine
import SnazzyCore
import SwiftUI

/// A floating 16:9 window showing exactly what will be recorded (screen +
/// inset). Like the camera previews, it never appears in a recording.
@MainActor
final class CompositePreviewWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    var onClose: (() -> Void)?

    var windowNumber: Int? { panel.isVisible ? panel.windowNumber : nil }

    init(capture: CaptureController) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 315),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        super.init()
        panel.title = "Recording preview"
        panel.level = .floating
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 240, height: 160)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: CompositePreviewContent().environment(capture))
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 20, y: vf.maxY - panel.frame.height - 20))
        }
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.close() }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// Live composite of screen + inset.
struct CompositePreview: NSViewRepresentable {
    let capture: CaptureController
    /// Passed so layout/crop changes trigger a redraw.
    let spec: CompositeSpec

    func makeNSView(context: Context) -> ImagePreviewView {
        let view = ImagePreviewView()
        view.provider = { [weak capture] in capture?.compositeFrame() }
        return view
    }

    func updateNSView(_ view: ImagePreviewView, context: Context) {
        view.invalidate()
    }
}

struct CompositePreviewContent: View {
    @Environment(CaptureController.self) private var capture

    var body: some View {
        ZStack(alignment: .top) {
            CompositePreview(capture: capture, spec: capture.compositeSpec)
            if capture.screen.state != .live {
                Label(screenMessage, systemImage: "rectangle.dashed")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .background(Color.black)
    }

    private var screenMessage: String {
        if capture.screenSource == nil {
            return capture.setup.source == .slides ? "Slides capture arrives in phase 6" : "Choose a display or window to record"
        }
        return capture.screen.state.description
    }
}
