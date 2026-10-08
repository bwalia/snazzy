import Builder
import Foundation
import Observation
import SnazzyCore
import WebKit

/// The live preview of the open project (deck or prototype) on iPad/iPhone,
/// with slide navigation and the deck's speaker notes.
@MainActor @Observable
final class StudioPreview: NSObject {
    struct Slide: Identifiable, Hashable {
        let id: Int
        let title: String
        let notes: String
    }

    private(set) var current: BuilderProject?
    private(set) var slides: [Slide] = []
    private(set) var currentSlide = 0
    private(set) var consoleErrors: [String] = []

    let workspace: Workspace
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let schemeHandler: ProjectSchemeHandler

    init(workspace: Workspace) {
        self.workspace = workspace
        try? FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: true)
        schemeHandler = ProjectSchemeHandler(workspace: workspace)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ProjectSchemeHandler.scheme)
        config.userContentController.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        super.init()
        config.userContentController.add(WeakHandler(self), name: "snazzy")
        #if DEBUG
        webView.isInspectable = true
        #endif
        if let latest = workspace.listProjects().first { open(latest.name) }
    }

    var projects: [BuilderProject] { workspace.listProjects() }

    /// The open deck's outline (decks from the slide editor and samples).
    var outline: DeckOutline? {
        guard let current else { return nil }
        _ = slides  // refresh after edits
        return DeckOutline.load(from: workspace, project: current.name)
    }

    func createDeck(_ outline: DeckOutline) throws {
        let p = try DeckOutline.create(outline, in: workspace)
        open(p.name)
    }

    func saveDeck(_ outline: DeckOutline) throws {
        guard let current else { return }
        try outline.save(to: workspace, project: current.name)
        reload()
    }
    var isDeck: Bool { !slides.isEmpty }

    func open(_ name: String) {
        guard let p = workspace.listProjects().first(where: { $0.name == Workspace.slug(name) }) else { return }
        current = p
        slides = []
        currentSlide = 0
        reload()
    }

    func reload() {
        guard let current, let url = ProjectSchemeHandler.url(project: current.name) else { return }
        consoleErrors = []
        webView.load(URLRequest(url: url))
    }

    func goToSlide(_ i: Int) {
        guard isDeck else { return }
        let index = max(0, min(i, slides.count - 1))
        webView.evaluateJavaScript("window.snazzyDeck && window.snazzyDeck.show(\(index))", completionHandler: nil)
        currentSlide = index
    }

    func next() { goToSlide(currentSlide + 1) }
    func previous() { goToSlide(currentSlide - 1) }

    /// A summary for the assistant: title, slides, errors.
    func report() async -> JSONValue {
        try? await Task.sleep(for: .milliseconds(600))
        let title = (try? await webView.evaluateJavaScript("document.title")) as? String ?? ""
        return [
            "project": .string(current?.name ?? ""),
            "title": .string(title),
            "slides": .number(Double(slides.count)),
            "current_slide": .number(Double(currentSlide)),
            "console_errors": .array(consoleErrors.prefix(10).map { .string($0) }),
        ]
    }

    fileprivate func receive(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "error":
            if let m = body["message"] as? String { consoleErrors.append(m) }
        case "deck":
            let list = (body["slides"] as? [[String: Any]]) ?? []
            slides = list.enumerated().map { i, s in Slide(id: i, title: s["title"] as? String ?? "Slide \(i + 1)", notes: s["notes"] as? String ?? "") }
            currentSlide = (body["index"] as? NSNumber)?.intValue ?? 0
        case "slide":
            currentSlide = (body["index"] as? NSNumber)?.intValue ?? currentSlide
        default:
            break
        }
    }

    /// Errors, the deck's slides (title + notes) on load, and slide changes.
    static let bridgeScript = """
        (function () {
          // Lay the page out at the view's real width (iOS assumes 980 px without this).
          const vp = document.createElement('meta');
          vp.name = 'viewport'; vp.content = 'width=device-width, initial-scale=1, maximum-scale=1';
          (document.head || document.documentElement).appendChild(vp);
          const post = m => { try { window.webkit.messageHandlers.snazzy.postMessage(m); } catch (e) {} };
          addEventListener('error', e => post({ type: 'error', message: e.message + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '') }));
          const origError = console.error;
          console.error = function () { post({ type: 'error', message: Array.from(arguments).join(' ') }); return origError.apply(console, arguments); };
          addEventListener('load', () => {
            const d = window.snazzyDeck;
            if (!d) { post({ type: 'deck', slides: [], index: 0 }); return; }
            const slides = Array.from(document.querySelectorAll('.slide')).map((s, i) => {
              const h = s.querySelector('h1, h2, blockquote, h3'); const n = s.querySelector('.notes');
              return { title: h ? h.textContent.trim().slice(0, 120) : 'Slide ' + (i + 1), notes: n ? n.textContent.trim() : '' };
            });
            post({ type: 'deck', slides, index: d.current() });
            let last = d.current();
            setInterval(() => { const c = d.current(); if (c !== last) { last = c; post({ type: 'slide', index: c }); } }, 200);
          });
        })();
        """
}

/// Avoids a retain cycle between the web view's content controller and the model.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: StudioPreview?
    init(_ target: StudioPreview) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { target?.receive(body) }
    }
}
