import Builder
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves builder project files as `snazzy-project://<project>/<path>`.
/// Pages loaded this way are same-origin, so script errors keep their real
/// messages (file:// would report every error as "Script error."), and only
/// files inside the project can be read.
final class ProjectSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "snazzy-project"
    let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    static func url(project: String, path: String = "index.html") -> URL? {
        URL(string: "\(scheme)://\(project)/\(path)")
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let project = url.host() else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        do {
            let file = try workspace.resolve(project: project, path: path)
            let data = try Data(contentsOf: file)
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let textual = mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("json") || mime.contains("svg")
            var headers = [
                "Content-Type": textual ? "\(mime); charset=utf-8" : mime,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
            ]
            // A project from someone else may only load its own files: no requests to the
            // internet (a page can tighten this policy, never loosen it).
            if workspace.project(project)?.shared == true {
                headers["Content-Security-Policy"] = "default-src 'self' \(Self.scheme)://\(project) 'unsafe-inline' 'unsafe-eval' data: blob:"
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(response)
            task.didReceive(Data("Not found: \(path)".utf8))
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
