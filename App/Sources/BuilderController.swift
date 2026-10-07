import AppKit
import Builder
import Foundation
import Observation
import SnazzyCore
import WebKit

/// The builder agent's workspace: projects of HTML/CSS/JS files, a live web
/// preview, console capture, and a log of what the agent is doing. The
/// assistant's builder tools and the Builder tab call these methods.
@MainActor @Observable
final class BuilderController {
    struct Step: Identifiable, Hashable {
        enum Kind: Hashable { case info, writing, wrote, error }
        let id = UUID()
        let date = Date()
        let kind: Kind
        let text: String
    }

    struct ConsoleEntry: Identifiable, Hashable {
        let id = UUID()
        let date = Date()
        let level: String
        let message: String
    }

    /// A file the model is writing right now (streamed tool arguments).
    struct LiveWrite: Equatable {
        var callID: String
        var path: String
        var content: String
    }

    let workspace: Workspace
    private(set) var projects: [BuilderProject] = []
    private(set) var current: BuilderProject?
    private(set) var files: [String] = []
    var selectedFile: String? { didSet { loadSelectedFile() } }
    private(set) var selectedContent = ""
    private(set) var live: LiveWrite?
    private(set) var steps: [Step] = []
    private(set) var console: [ConsoleEntry] = []
    private(set) var isLoading = false
    private(set) var reloadCount = 0

    /// Called when the builder starts working, so the UI can show the Builder tab.
    @ObservationIgnored var onActivity: (() -> Void)?
    /// Called when the result window opens (so screen capture can include it).
    @ObservationIgnored var onPopOut: (() -> Void)?
    /// Session log hook.
    @ObservationIgnored var onStep: ((Step) -> Void)?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let bridge = WebBridge()
    @ObservationIgnored private var liveBuffers: [String: String] = [:]
    @ObservationIgnored private var lastLiveUpdate = Date.distantPast
    @ObservationIgnored private var popOut: NSWindow?
    @ObservationIgnored private var popOutWeb: WKWebView?

    init(workspace: Workspace = Workspace(root: Workspace.defaultRoot())) {
        self.workspace = workspace
        webView = Self.makeWebView(bridge: bridge)
        bridge.onConsole = { [weak self] level, message in self?.addConsole(level, message) }
        bridge.onLoad = { [weak self] loading in self?.isLoading = loading }
        try? FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
        projects = workspace.listProjects()
        if let latest = projects.first { open(latest.name, announce: false) }
    }

    private static func makeWebView(bridge: WebBridge) -> WKWebView {
        let config = WKWebViewConfiguration()
        let script = WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(bridge, name: "snazzy")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Project files load from file://; without this WebKit treats each script
        // as cross-origin and reports every error as just "Script error.".
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = bridge
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    /// Forwards console output and page errors to the app.
    static let consoleScript = """
        (function () {
          const send = (level, args) => {
            try {
              const message = Array.from(args).map(a => {
                if (a instanceof Error) return a.message;
                try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); }
              }).join(' ');
              window.webkit.messageHandlers.snazzy.postMessage({ level, message: message.slice(0, 2000) });
            } catch (e) {}
          };
          ['log', 'info', 'warn', 'error'].forEach(level => {
            const original = console[level];
            console[level] = function () { send(level, arguments); return original.apply(console, arguments); };
          });
          window.addEventListener('error', e => {
            const where = e.filename ? ` (${e.filename.split('/').pop()}:${e.lineno})` : '';
            send('error', [e.message + where]);
          });
          window.addEventListener('unhandledrejection', e => send('error', ['Unhandled promise rejection: ' + (e.reason && e.reason.message || e.reason)]));
        })();
        """

    // MARK: Projects

    func refreshProjects() {
        projects = workspace.listProjects()
    }

    @discardableResult
    func createProject(name: String, kind: ProjectKind, title: String?) throws -> BuilderProject {
        onActivity?()
        let project = try workspace.createProject(name: name, kind: kind, title: title)
        refreshProjects()
        open(project.name, announce: false)
        step(.info, "Project \(project.name) (\(kind.rawValue)) ready")
        return project
    }

    func open(_ name: String, announce: Bool = true) {
        guard let project = workspace.listProjects().first(where: { $0.name == Workspace.slug(name) }) else { return }
        current = project
        files = workspace.files(project: project.name)
        selectedFile = files.contains("index.html") ? "index.html" : files.first
        console.removeAll()
        reload()
        if announce { step(.info, "Opened \(project.name)") }
    }

    func requireProject(_ name: String?) throws -> BuilderProject {
        if let name, !name.isEmpty {
            guard let p = workspace.listProjects().first(where: { $0.name == Workspace.slug(name) }) else {
                throw WorkspaceError("No project named \(name). Projects: " + workspace.listProjects().map(\.name).joined(separator: ", "))
            }
            if current?.name != p.name { open(p.name) }
            return p
        }
        guard let current else { throw WorkspaceError("No project open. Call create_project first.") }
        return current
    }

    func deleteProject(_ name: String) throws {
        try workspace.deleteProject(name)
        if current?.name == Workspace.slug(name) {
            current = nil
            files = []
            selectedFile = nil
            webView.loadHTMLString("", baseURL: nil)
        }
        refreshProjects()
        step(.info, "Deleted project \(name)")
    }

    func revealInFinder() {
        guard let current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([workspace.projectURL(current.name)])
    }

    // MARK: Files

    /// Writes a file, reloads the preview and returns what the page reported.
    func writeFile(project: String?, path: String, content: String) async throws -> JSONValue {
        onActivity?()
        let p = try requireProject(project)
        try workspace.write(project: p.name, path: path, content: content)
        live = nil
        files = workspace.files(project: p.name)
        selectedFile = path
        step(.wrote, "Wrote \(path) (\(ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)))")
        return try await reloadAndReport()
    }

    func readFile(project: String?, path: String) throws -> String {
        let p = try requireProject(project)
        return try workspace.read(project: p.name, path: path)
    }

    func deleteFile(project: String?, path: String) throws {
        let p = try requireProject(project)
        try workspace.delete(project: p.name, path: path)
        files = workspace.files(project: p.name)
        if selectedFile == path { selectedFile = files.first }
        step(.info, "Deleted \(path)")
        reload()
    }

    private func loadSelectedFile() {
        guard let current, let selectedFile else { selectedContent = ""; return }
        selectedContent = (try? workspace.read(project: current.name, path: selectedFile)) ?? ""
    }

    // MARK: Live writing (streamed tool input)

    /// Called with each fragment of a write_file call's JSON arguments.
    func liveInput(callID: String, fragment: String) {
        liveBuffers[callID, default: ""] += fragment
        // Throttle UI updates to ~15 per second.
        guard Date().timeIntervalSince(lastLiveUpdate) > 0.066 else { return }
        lastLiveUpdate = Date()
        let buffer = liveBuffers[callID] ?? ""
        guard let path = PartialJSON.stringValue(forKey: "path", in: buffer) else { return }
        let content = PartialJSON.stringValue(forKey: "content", in: buffer) ?? ""
        if live?.callID != callID {
            onActivity?()
            step(.writing, "Writing \(path)…")
        }
        live = LiveWrite(callID: callID, path: path, content: content)
    }

    func liveFinished(callID: String) {
        liveBuffers[callID] = nil
        if live?.callID == callID { live = nil }
    }

    // MARK: Preview

    var indexURL: URL? {
        guard let current else { return nil }
        let dir = workspace.projectURL(current.name)
        let index = dir.appending(path: "index.html")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }

    func reload() {
        guard let current, let url = indexURL else { return }
        let dir = workspace.projectURL(current.name)
        console.removeAll()
        reloadCount += 1
        // Keep the deck on the same slide across reloads.
        let target = webView.url?.path == url.path ? URL(string: url.absoluteString + (webView.url?.fragment.map { "#\($0)" } ?? "")) ?? url : url
        webView.loadFileURL(target, allowingReadAccessTo: dir)
        if let popOutWeb { popOutWeb.loadFileURL(url, allowingReadAccessTo: dir) }
    }

    /// Reloads, waits for the page to settle, and reports errors and a summary.
    func reloadAndReport() async throws -> JSONValue {
        reload()
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<40 where isLoading { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(700))  // let scripts run
        return try await report()
    }

    func report() async throws -> JSONValue {
        let summary = try? await webView.evaluateJavaScript("""
            JSON.stringify({
              title: document.title,
              text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').trim().slice(0, 600),
              elements: document.getElementsByTagName('*').length,
              slides: window.snazzyDeck ? window.snazzyDeck.count() : null,
              current_slide: window.snazzyDeck ? window.snazzyDeck.current() : null
            })
            """) as? String
        let errors = console.filter { $0.level == "error" }.map(\.message)
        let warnings = console.filter { $0.level == "warn" }.map(\.message)
        var out: [String: JSONValue] = [
            "project": .string(current?.name ?? ""),
            "files": .array(files.map { .string($0) }),
            "console_errors": .array(errors.prefix(20).map { .string($0) }),
            "console_warnings": .array(warnings.prefix(10).map { .string($0) }),
        ]
        if let summary, let page = try? JSONValue.parse(summary) { out["page"] = page }
        if !errors.isEmpty { step(.error, "\(errors.count) console error\(errors.count == 1 ? "" : "s"): \(errors[0])") }
        return .object(out)
    }

    /// A PNG of the preview as it looks now.
    func snapshot(width: CGFloat = 1280) async -> Data? {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(width))
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func showSlide(_ index: Int) async throws -> JSONValue {
        _ = try? await webView.evaluateJavaScript("window.snazzyDeck && window.snazzyDeck.show(\(index))")
        return try await report()
    }

    /// The result window's number, so screen recordings include it.
    var popOutWindowNumber: Int? { popOut?.isVisible == true ? popOut?.windowNumber : nil }

    /// A bigger, separate window showing the result (e.g. to present a deck).
    func openPopOut() {
        guard let current, let url = indexURL else { return }
        if popOut == nil {
            let config = WKWebViewConfiguration()
            let web = WKWebView(frame: .zero, configuration: config)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.contentView = web
            window.isReleasedWhenClosed = false
            window.center()
            popOut = window
            popOutWeb = web
        }
        popOut?.title = current.name
        popOutWeb?.loadFileURL(url, allowingReadAccessTo: workspace.projectURL(current.name))
        popOut?.makeKeyAndOrderFront(nil)
        onPopOut?()
    }

    // MARK: Log

    private func addConsole(_ level: String, _ message: String) {
        console.append(ConsoleEntry(level: level, message: message))
        if console.count > 300 { console.removeFirst(console.count - 300) }
    }

    func step(_ kind: Step.Kind, _ text: String) {
        let s = Step(kind: kind, text: text)
        steps.append(s)
        if steps.count > 300 { steps.removeFirst(steps.count - 300) }
        onStep?(s)
    }

    func stateJSON() -> JSONValue {
        [
            "projects": .array(projects.map { ["name": .string($0.name), "kind": .string($0.kind.rawValue)] }),
            "open_project": current.map { ["name": .string($0.name), "kind": .string($0.kind.rawValue),
                                           "files": .array(files.map { .string($0) })] } ?? .null,
        ]
    }
}

/// WebKit delegates (NSObject) that forward to the controller.
final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onConsole: ((String, String) -> Void)?
    var onLoad: ((Bool) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let level = body["level"] as? String ?? "log"
        let text = body["message"] as? String ?? ""
        MainActor.assumeIsolated { onConsole?(level, text) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { onLoad?(true) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { onLoad?(false) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            onConsole?("error", "Page failed to load: \(error.localizedDescription)")
            onLoad?(false)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            onConsole?("error", "Page failed to load: \(error.localizedDescription)")
            onLoad?(false)
        }
    }
}
