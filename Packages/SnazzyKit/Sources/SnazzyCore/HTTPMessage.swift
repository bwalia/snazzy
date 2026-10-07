import Foundation

/// A minimal HTTP/1.1 request (headers lower-cased).
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// The path without the query string.
    public var route: String { String(path.split(separator: "?", maxSplits: 1).first ?? "") }

    /// Query parameters (last value wins).
    public var query: [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first,
              let items = URLComponents(string: "?" + q)?.queryItems else { return [:] }
        return items.reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
    }

    public enum ParseResult: Equatable, Sendable {
        case complete(HTTPRequest)
        case incomplete
        case invalid
    }

    public static func parse(_ data: Data, maxBody: Int = 8_000_000) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxBody else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .complete(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body)))
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public var contentType = "application/json"
    public var extraHeaders: [String: String] = [:]

    public init(status: Int, body: Data, contentType: String = "application/json", extraHeaders: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.extraHeaders = extraHeaders
    }

    public var serialized: Data {
        let reason = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
                      429: "Too Many Requests", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
