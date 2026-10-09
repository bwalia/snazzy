import Foundation

/// The Terms of Use and Privacy Policy people agree to on first launch.
/// Bump `termsVersion` when the terms change in a way that matters: the
/// welcome screen asks again.
public enum Legal {
    public static let termsVersion = 1
    public static let termsURL = URL(string: "https://www.snazzy.pro/terms.html")!
    public static let privacyURL = URL(string: "https://www.snazzy.pro/privacy.html")!
    static let acceptedKey = "SnazzyPro.acceptedTermsVersion"
    static let acceptedDateKey = "SnazzyPro.acceptedTermsDate"

    public static func hasAccepted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: acceptedKey) >= termsVersion
    }

    public static func accept(_ defaults: UserDefaults = .standard, date: Date = Date()) {
        defaults.set(termsVersion, forKey: acceptedKey)
        defaults.set(date, forKey: acceptedDateKey)
    }

    public static func acceptedDate(_ defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: acceptedDateKey) as? Date
    }

    /// The two documents, shipped inside the app (the website's own pages), so
    /// they can be read on the welcome screen without going online.
    public enum Document: String, CaseIterable, Identifiable, Sendable {
        case terms, privacy
        public var id: String { rawValue }
        public var title: String { self == .terms ? "Terms of Use" : "Privacy Policy" }
        public var url: URL { self == .terms ? Legal.termsURL : Legal.privacyURL }
        /// The bundled copy of the website page.
        public var resourceName: String { rawValue }
    }

    /// A self-contained page for reading a document inside the app: the
    /// `<main class="doc">` part of the website page, styled for the app's light
    /// or dark mode (a web view can't always tell). Nothing in it loads from the network.
    public static func readerPage(fromSiteHTML html: String, dark: Bool = false) -> String? {
        guard let start = html.range(of: #"<main class="doc">"#),
              let end = html.range(of: "</main>", range: start.upperBound..<html.endIndex) else { return nil }
        var body = String(html[start.upperBound..<end.lowerBound])
        // No scripts or images: text only.
        for pattern in [#"<script[\s\S]*?</script>"#, #"<img[^>]*>"#] {
            body = body.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            :root { color-scheme: \(dark ? "dark" : "light"); \(dark ? "--fg: #f2f2f7; --muted: #a1a1a6; --link: #9d93ff;" : "--fg: #1d1d1f; --muted: #6e6e73; --link: #5b4dff;") }
            body { font: 13px/1.5 -apple-system, system-ui, sans-serif; color: var(--fg); background: transparent; margin: 14px 16px; }
            h1 { font-size: 18px; margin: 0 0 2px; } h2 { font-size: 14px; margin: 18px 0 4px; }
            .updated { color: var(--muted); margin-top: 0; } a { color: var(--link); } ul, ol { padding-left: 20px; }
            </style></head><body>\(body)</body></html>
            """
    }

    /// The version number the page shows ("Version 1 · …"), to check it matches `termsVersion`.
    public static func pageVersion(fromSiteHTML html: String) -> Int? {
        guard let m = html.range(of: #"class="updated">Version (\d+)"#, options: .regularExpression) else { return nil }
        return Int(html[m].filter(\.isNumber))
    }
}
