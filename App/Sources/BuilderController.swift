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

    /// One slide of the open deck: its heading and speaker notes.
    struct DeckSlide: Identifiable, Hashable {
        let id: Int
        let title: String
        let notes: String
        /// A title or closing slide (`<section class="slide title">`).
        var isTitle = false

        var displayTitle: String { title.isEmpty ? "Slide \(id + 1)" : title }
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
    /// Slides of the open deck (empty when the project isn't a deck).
    private(set) var deckSlides: [DeckSlide] = []
    /// The slide showing in the preview and the Present window (they stay in step).
    private(set) var currentSlide = 0
    /// Bumped when a deck is added, removed, edited or re-labelled, so the library re-reads.
    private(set) var libraryVersion = 0
    /// Slide to show once the deck being opened has loaded (from search).
    @ObservationIgnored private var pendingSlide: Int?
    /// Whether the Present window is open.
    private(set) var stageOpen = false

    /// Called when the builder starts working, so the UI can show the Builder tab.
    @ObservationIgnored var onActivity: (() -> Void)?
    /// Called when the result window opens (so screen capture can include it).
    @ObservationIgnored var onPopOut: (() -> Void)?
    /// Session log hook.
    @ObservationIgnored var onStep: ((Step) -> Void)?
    /// The slide changed (from the keyboard, a click, the assistant or a remote).
    @ObservationIgnored var onSlideChange: ((Int, DeckSlide?) -> Void)?
    /// The Present window opened, closed, moved or resized.
    @ObservationIgnored var onStageChange: (() -> Void)?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let bridge = WebBridge()
    @ObservationIgnored private let deckBridge = DeckBridge()
    @ObservationIgnored private let stageDelegate = StageWindowDelegate()
    @ObservationIgnored private let schemeHandler: ProjectSchemeHandler
    @ObservationIgnored private var liveBuffers: [String: String] = [:]
    @ObservationIgnored private var lastLiveUpdate = Date.distantPast
    @ObservationIgnored private var popOut: NSWindow?
    @ObservationIgnored private var popOutWeb: WKWebView?

    init(workspace: Workspace = Workspace(root: Workspace.defaultRoot())) {
        self.workspace = workspace
        schemeHandler = ProjectSchemeHandler(workspace: workspace)
        webView = Self.makeWebView(bridge: bridge, deckBridge: deckBridge, schemeHandler: schemeHandler)
        bridge.onConsole = { [weak self] level, message in self?.addConsole(level, message) }
        deckBridge.onMessage = { [weak self] web, index, slides in self?.deckMessage(from: web, index: index, slides: slides) }
        stageDelegate.onChange = { [weak self] in self?.stageChanged() }
        bridge.onLoad = { [weak self] loading in self?.isLoading = loading }
        try? FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
        projects = workspace.listProjects()
        if let latest = projects.first { open(latest.name, announce: false) }
    }

    private static func makeWebView(bridge: WebBridge?, deckBridge: DeckBridge, schemeHandler: ProjectSchemeHandler) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Keep drawing when the window is covered: the Present window is
        // recorded even when other windows are on top of it.
        if #available(macOS 14.0, *) {
            config.preferences.inactiveSchedulingPolicy = .none
        }
        config.userContentController.addUserScript(WKUserScript(source: deckScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(deckBridge, name: "snazzyDeck")
        // Project files are served from a custom scheme (same-origin, so errors stay readable).
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ProjectSchemeHandler.scheme)
        if let bridge {
            let script = WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(script)
            config.userContentController.add(bridge, name: "snazzy")
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = bridge ?? NavigationGuard.shared
        #if DEBUG
        view.isInspectable = true
        #endif
        return view
    }

    /// Reports the deck's slides (heading + speaker notes) on load and the
    /// current slide whenever it changes. Works with any deck that exposes
    /// `window.snazzyDeck` (the presentation template does).
    static let deckScript = """
        (function () {
          let last = null;
          const post = (m) => { try { window.webkit.messageHandlers.snazzyDeck.postMessage(m); } catch (e) {} };
          function slides() {
            return Array.from(document.querySelectorAll('.slide')).map(s => {
              const h = s.querySelector('h1, h2, blockquote, h3');
              const n = s.querySelector('.notes');
              return { title: h ? h.textContent.replace(/\\s+/g, ' ').trim().slice(0, 160) : '',
                       notes: n ? n.textContent.trim().slice(0, 4000) : '',
                       isTitle: s.classList.contains('title') };
            });
          }
          function tick(full) {
            const d = window.snazzyDeck;
            if (!d) { if (full) post({ index: -1, slides: [] }); return; }
            const i = d.current();
            if (!full && i === last) return;
            last = i;
            post(full ? { index: i, slides: slides() } : { index: i });
          }
          const start = () => { tick(true); setInterval(() => tick(false), 150); };
          if (document.readyState === 'complete') start(); else addEventListener('load', start);
        })();
        """

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
        libraryVersion += 1
    }

    /// Opens a deck at a slide (a search result). Waits for the page if it isn't open yet.
    func open(_ name: String, slide: Int) {
        if current?.name == Workspace.slug(name), isDeckOpen {
            goToSlide(slide)
        } else {
            pendingSlide = slide
            open(name, announce: false)
        }
    }

    /// Sets how a deck is organised in the library.
    @discardableResult
    func setDetails(project: String, category: String?, tags: [String]) throws -> BuilderProject {
        let p = try workspace.setDetails(project, category: category, tags: tags)
        refreshProjects()
        if current?.name == p.name { current = p }
        return p
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

    /// The open deck's outline, if it was made in the slide editor or is a sample.
    var outline: DeckOutline? {
        guard let current else { return nil }
        _ = reloadCount  // refresh after edits
        return DeckOutline.load(from: workspace, project: current.name)
    }

    /// A new deck from the slide editor (no AI needed).
    func createDeck(_ outline: DeckOutline) throws {
        onActivity?()
        let p = try DeckOutline.create(outline, in: workspace)
        refreshProjects()
        open(p.name, announce: false)
        step(.info, "Deck \(p.name) created in the slide editor")
    }

    /// Saves edits from the slide editor and reloads the preview.
    func saveDeck(_ outline: DeckOutline) throws {
        guard let current else { return }
        try outline.save(to: workspace, project: current.name)
        files = workspace.files(project: current.name)
        reload()
        step(.wrote, "Slides saved from the slide editor")
    }

    /// Copies a sample deck into the workspace and opens it.
    @discardableResult
    func openSample(_ sample: SampleDeck) throws -> BuilderProject {
        onActivity?()
        let project = try workspace.createSample(sample)
        refreshProjects()
        open(project.name, announce: false)
        step(.info, "Sample “\(sample.title)” is in \(project.name)")
        return project
    }

    func open(_ name: String, announce: Bool = true) {
        guard let project = workspace.listProjects().first(where: { $0.name == Workspace.slug(name) }) else { return }
        if current?.name != project.name {
            currentSlide = 0
            deckSlides = []
        }
        current = project
        files = workspace.files(project: project.name)
        selectedFile = files.contains("index.html") ? "index.html" : files.first
        console.removeAll()
        reload()
        if announce { step(.info, "Opened \(project.name)") }
    }

    /// Lets the open project from someone else reach the internet (fonts, libraries, data).
    func allowInternet() {
        guard let name = current?.name else { return }
        do {
            try workspace.setShared(name, false)
            open(name, announce: false)
            step(.info, "\(name) can now reach the internet")
        } catch {
            step(.error, error.localizedDescription)
        }
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

    /// The run ended or was cancelled: nothing is being written any more.
    func clearLive() {
        liveBuffers = [:]
        live = nil
    }

    // MARK: Preview

    var indexURL: URL? {
        guard let current else { return nil }
        let index = workspace.projectURL(current.name).appending(path: "index.html")
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        return ProjectSchemeHandler.url(project: current.name)
    }

    func reload() {
        guard let url = indexURL else { return }
        console.removeAll()
        reloadCount += 1
        // Keep the deck on the same slide across reloads.
        let sameProject = webView.url?.host() == url.host()
        let target = sameProject ? URL(string: url.absoluteString + (webView.url?.fragment.map { "#\($0)" } ?? "")) ?? url : url
        webView.load(URLRequest(url: target))
        popOutWeb?.load(URLRequest(url: deckURL(url)))
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
        goToSlide(index)
        try? await Task.sleep(for: .milliseconds(250))
        return try await report()
    }

    // MARK: Slides

    /// Shows a slide in the preview and the Present window.
    func goToSlide(_ index: Int) {
        guard !deckSlides.isEmpty else { return }
        let i = max(0, min(index, deckSlides.count - 1))
        for web in [webView, popOutWeb].compactMap({ $0 }) {
            web.evaluateJavaScript("window.snazzyDeck && window.snazzyDeck.show(\(i))", completionHandler: nil)
        }
    }

    func nextSlide() { goToSlide(currentSlide + 1) }
    func previousSlide() { goToSlide(currentSlide - 1) }

    var isDeckOpen: Bool { !deckSlides.isEmpty }

    /// The URL with the current slide in the fragment (deck.js starts there).
    private func deckURL(_ url: URL) -> URL {
        guard isDeckOpen else { return url }
        return URL(string: url.absoluteString + "#\(currentSlide)") ?? url
    }

    private func deckMessage(from web: WKWebView?, index: Int, slides: [DeckSlide]?) {
        if let slides {
            // Full report after a page load. A page without a deck in the main preview clears the list.
            if web === webView || !slides.isEmpty, slides != deckSlides { deckSlides = slides }
            if web === webView, !slides.isEmpty, let slide = pendingSlide {
                pendingSlide = nil
                if slide != index { goToSlide(slide); return }
            }
        }
        guard index >= 0 else { return }
        let changed = index != currentSlide
        currentSlide = index
        // Keep the other view on the same slide.
        for other in [webView, popOutWeb].compactMap({ $0 }) where other !== web {
            other.evaluateJavaScript("window.snazzyDeck && window.snazzyDeck.current() !== \(index) && window.snazzyDeck.show(\(index))", completionHandler: nil)
        }
        if changed { onSlideChange?(index, deckSlides.indices.contains(index) ? deckSlides[index] : nil) }
    }

    // MARK: Present window

    /// The Present window's capture details: window ID, title bar height and
    /// size in points. Nil when it isn't open and visible.
    var stage: (windowID: UInt32, topInset: Double, size: CGSize)? {
        guard let w = popOut, w.isVisible, !w.isMiniaturized, w.windowNumber > 0 else { return nil }
        let top = max(0, w.frame.height - w.contentLayoutRect.height)
        return (UInt32(w.windowNumber), Double(top), w.frame.size)
    }

    func closePopOutIfOpen() {
        popOut?.close()
    }

    /// Stops the Present window being resized (while recording: the capture size is fixed).
    func setStageLocked(_ locked: Bool) {
        guard let w = popOut else { return }
        if locked { w.styleMask.remove(.resizable) } else { w.styleMask.insert(.resizable) }
    }

    private func stageChanged() {
        stageOpen = popOut?.isVisible == true
        onStageChange?()
    }

    /// The result window's number, so screen recordings include it.
    var popOutWindowNumber: Int? { popOut?.isVisible == true ? popOut?.windowNumber : nil }

    /// A bigger, separate window showing the result (e.g. to present a deck).
    func openPopOut() {
        guard let current, let url = indexURL else { return }
        if popOut == nil {
            let web = Self.makeWebView(bridge: nil, deckBridge: deckBridge, schemeHandler: schemeHandler)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.contentView = web
            window.isReleasedWhenClosed = false
            window.delegate = stageDelegate
            window.center()
            popOut = window
            popOutWeb = web
        }
        if current.kind == .presentation {
            popOut?.contentAspectRatio = NSSize(width: 16, height: 9)
            popOut?.title = "Present: \(current.name)"
        } else {
            popOut?.contentResizeIncrements = NSSize(width: 1, height: 1)
            popOut?.title = current.name
        }
        popOutWeb?.load(URLRequest(url: deckURL(url)))
        popOut?.makeKeyAndOrderFront(nil)
        #if DEBUG
        if ProcessInfo.processInfo.environment["SNAZZY_STAGE_BACK"] != nil { popOut?.orderBack(nil) }
        #endif
        stageChanged()
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
            "deck": isDeckOpen ? deckJSON() : .null,
        ]
    }

    func deckJSON() -> JSONValue {
        [
            "current_slide": .number(Double(currentSlide)),
            "slide_count": .number(Double(deckSlides.count)),
            "present_window_open": .bool(stageOpen),
            "slides": .array(deckSlides.map { ["index": .number(Double($0.id)), "title": .string($0.displayTitle), "has_notes": .bool(!$0.notes.isEmpty)] }),
        ]
    }
}

/// WebKit delegates (NSObject) that forward to the controller.
/// Keeps a page on its project: a clicked link to a website opens in the browser,
/// and nothing can take the preview or the (recorded) Present window to another site.
class NavigationGuard: NSObject, WKNavigationDelegate {
    static let shared = NavigationGuard()

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.cancel) }
            // Frames inside a page (a video embed) are the page's business; shared projects can't load them.
            if action.targetFrame?.isMainFrame == false || [ProjectSchemeHandler.scheme, "about", "data", "blob"].contains(scheme) {
                return decisionHandler(.allow)
            }
            if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(scheme) { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}

final class WebBridge: NavigationGuard, WKScriptMessageHandler {
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

/// Receives slide reports from the deck script (preview and Present window).
final class DeckBridge: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKWebView?, Int, [BuilderController.DeckSlide]?) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let index = (body["index"] as? NSNumber)?.intValue ?? -1
        let slides = (body["slides"] as? [[String: Any]]).map { list in
            list.enumerated().map { i, s in
                BuilderController.DeckSlide(id: i, title: s["title"] as? String ?? "", notes: s["notes"] as? String ?? "",
                                            isTitle: s["isTitle"] as? Bool ?? false)
            }
        }
        let web = message.webView
        MainActor.assumeIsolated { onMessage?(web, index, slides) }
    }
}

/// Tells the controller when the Present window closes, moves or resizes.
@MainActor
final class StageWindowDelegate: NSObject, NSWindowDelegate {
    var onChange: (() -> Void)?

    private func changed() {
        // After AppKit finishes updating the window.
        Task { @MainActor [weak self] in self?.onChange?() }
    }

    func windowWillClose(_ notification: Notification) { changed() }
    func windowDidEndLiveResize(_ notification: Notification) { changed() }
    func windowDidMiniaturize(_ notification: Notification) { changed() }
    func windowDidDeminiaturize(_ notification: Notification) { changed() }
    func windowDidChangeScreen(_ notification: Notification) { changed() }
}
