import SnazzyCore
import SwiftUI
import WebKit

/// The Terms of Use and Privacy Policy, readable on the welcome screen. They
/// come from the copies inside the app (the website's own pages), so nothing
/// goes online before the user has agreed. Links open in the browser.
struct LegalDocumentsView: View {
    @State private var doc: Legal.Document = .terms
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            Picker("Document", selection: $doc) {
                ForEach(Legal.Document.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LegalPageView(html: Self.page(doc, dark: colorScheme == .dark))
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                .accessibilityLabel(doc.title)
            HStack {
                Spacer()
                Link("View online", destination: doc.url).font(.caption)
            }
        }
    }

    static func page(_ doc: Legal.Document, dark: Bool) -> String {
        guard let url = Bundle.main.url(forResource: doc.resourceName, withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8),
              let page = Legal.readerPage(fromSiteHTML: html, dark: dark) else {
            return "<p style=\"font: 13px -apple-system\">The \(doc.title) is at \(doc.url.absoluteString)</p>"
        }
        return page
    }
}

/// One local page: a web view on iPhone and iPad, rich text on the Mac.
/// Links open in the browser.
@MainActor private struct LegalPageView {
    let html: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The page on screen, so it isn't reloaded on every SwiftUI update.
        var shown = ""

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated else { return .allow }
            if let url = action.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") {
                #if os(iOS)
                await UIApplication.shared.open(url)
                #endif
            }
            return .cancel
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(iOS)
    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        return web
    }

    private func show(_ web: WKWebView, _ coordinator: Coordinator) {
        guard coordinator.shown != html else { return }
        coordinator.shown = html
        web.loadHTMLString(html, baseURL: nil)
    }
    #endif
}

#if os(macOS)
/// On the Mac a web view in the welcome sheet stayed blank, so the page is
/// shown as rich text instead: same content, selectable, links clickable.
extension LegalPageView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 6, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.shown != html, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.shown = html
        if let rich = NSAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            text.textStorage?.setAttributedString(rich)
        }
        text.scrollToBeginningOfDocument(nil)
    }
}
#else
extension LegalPageView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { show(web, context.coordinator) }
}
#endif
