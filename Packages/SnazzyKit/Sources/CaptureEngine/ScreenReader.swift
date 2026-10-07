import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import SnazzyCore
@preconcurrency import Vision

/// Reads the text of what the user is showing: the frontmost window of
/// another app. Uses Accessibility when the app is allowed to (not possible
/// in the App Store sandbox), otherwise on-device text recognition (Vision)
/// on a ScreenCaptureKit screenshot of that window.
public enum ScreenReader {
    public struct Line: Sendable, Hashable {
        public var text: String
        /// Normalised box, top-left origin (0…1) within the captured image.
        public var box: CGRect
    }

    public struct Capture: Sendable {
        public var app: String
        public var title: String
        public var method: String
        public var lines: [Line]
        public var text: String { lines.map(\.text).joined(separator: "\n") }
    }

    /// The frontmost normal window that isn't Snazzy Pro's (any instance).
    public static func frontWindow() -> (id: CGWindowID, pid: pid_t, app: String, title: String)? {
        let own = ProcessInfo.processInfo.processIdentifier
        let ownBundle = Bundle.main.bundleIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  ownBundle == nil || NSRunningApplication(processIdentifier: pid)?.bundleIdentifier != ownBundle,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? Double ?? 0) > 200, (bounds["Height"] as? Double ?? 0) > 120 else { continue }
            let app = w[kCGWindowOwnerName as String] as? String ?? "App"
            if ["Dock", "Window Server", "Control Centre", "Control Center", "Notification Centre", "Notification Center"].contains(app) { continue }
            return (id, pid, app, w[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }

    public static func readFrontWindow() async throws -> Capture {
        guard let front = frontWindow() else { throw CaptureError("No other app window is open.") }
        if AXIsProcessTrusted(), let text = accessibilityText(pid: front.pid), text.count > 20 {
            let lines = text.components(separatedBy: .newlines).map { Line(text: $0, box: .zero) }
            return Capture(app: front.app, title: front.title, method: "accessibility", lines: lines)
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError("Screen Recording permission is needed to read the window. Allow it in the Sources tab.")
        }
        let image = try await screenshot(windowID: front.id)
        return Capture(app: front.app, title: front.title, method: "on-device text recognition", lines: try recognize(image))
    }

    static func screenshot(windowID: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError("That window can't be captured.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// On-device OCR, lines in reading order.
    public static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false  // code and logs: keep text exact
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { obs -> Line? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox  // bottom-left origin
            return Line(text: text, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        return order(lines)
    }

    /// Top to bottom, then left to right (lines within half a line height count as one row).
    static func order(_ lines: [Line]) -> [Line] {
        lines.sorted { a, b in
            if abs(a.box.midY - b.box.midY) < max(a.box.height, b.box.height) / 2 { return a.box.minX < b.box.minX }
            return a.box.midY < b.box.midY
        }
    }

    /// Text of the focused element (or its first text area) via Accessibility.
    static func accessibilityText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused else { return nil }
        return findText(window as! AXUIElement, depth: 0)
    }

    private static func findText(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXTextAreaRole as String {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, let s = value as? String { return s }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list { if let s = findText(child, depth: depth + 1) { return s } }
        return nil
    }

    /// A 16:9 region (top-left normalised) around the first line containing
    /// `text`, padded and at least 35% wide, kept inside the image.
    public static func zoomRegion(for text: String, in lines: [Line], imageAspect: CGFloat) -> CGRect? {
        let needle = text.lowercased()
        let hits = lines.filter { $0.text.lowercased().contains(needle) }
        guard let first = hits.first else { return nil }
        // Include following lines that are part of the same block (stack traces).
        var box = first.box
        for line in lines where line.box.minY > box.maxY && line.box.minY - box.maxY < first.box.height * 1.6 && box.height < 0.4 {
            box = box.union(line.box)
        }
        var w = max(box.width * 1.25, 0.35)
        var h = w * imageAspect / (16.0 / 9.0)  // keep the zoomed view 16:9 on the canvas
        if h < box.height * 1.3 { h = min(1, box.height * 1.3); w = h * (16.0 / 9.0) / imageAspect }
        w = min(w, 1); h = min(h, 1)
        let x = min(max(box.midX - w / 2, 0), 1 - w)
        let y = min(max(box.midY - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
