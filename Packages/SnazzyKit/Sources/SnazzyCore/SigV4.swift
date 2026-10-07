import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3-compatible storage (AWS S3, Cloudflare R2,
/// MinIO): signed request headers and pre-signed URLs.
public struct SigV4: Sendable {
    public var accessKey: String
    public var secretKey: String
    public var region: String
    public var service = "s3"

    public init(accessKey: String, secretKey: String, region: String, service: String = "s3") {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.service = service
    }

    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = sha256Hex(Data())

    /// Adds `x-amz-date`, `x-amz-content-sha256` and `Authorization` to a request.
    public func sign(_ request: inout URLRequest, payloadHash: String = SigV4.unsignedPayload, date: Date = Date()) {
        guard let url = request.url else { return }
        let (amzDate, day) = Self.stamps(date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        var headers: [String: String] = ["host": Self.hostHeader(url)]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonical = [
            request.httpMethod ?? "GET",
            Self.canonicalPath(url),
            Self.canonicalQuery(url),
            headers.keys.sorted().map { "\($0):\(headers[$0]!)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let signature = sign(canonical: canonical, amzDate: amzDate, day: day)
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope(day)), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// A URL anyone can use for `expires` seconds (max 7 days).
    public func presignedURL(method: String = "GET", url: URL, expires: Int, date: Date = Date()) -> URL {
        let (amzDate, day) = Self.stamps(date)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.percentEncodedQueryItems ?? []
        items += [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: Self.encode("\(accessKey)/\(scope(day))")),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(min(max(expires, 1), 604_800))),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]
        components.percentEncodedQueryItems = items
        let unsigned = components.url!
        let canonical = [method, Self.canonicalPath(unsigned), Self.canonicalQuery(unsigned),
                         "host:\(Self.hostHeader(unsigned))\n", "host", Self.unsignedPayload].joined(separator: "\n")
        let signature = sign(canonical: canonical, amzDate: amzDate, day: day)
        components.percentEncodedQueryItems = items + [URLQueryItem(name: "X-Amz-Signature", value: signature)]
        return components.url!
    }

    // MARK: Internals

    private func scope(_ day: String) -> String { "\(day)/\(region)/\(service)/aws4_request" }

    private func sign(canonical: String, amzDate: String, day: String) -> String {
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope(day), Self.sha256Hex(Data(canonical.utf8))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)).map { String(format: "%02x", $0) }.joined()
    }

    static func stamps(_ date: Date) -> (String, String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amz = f.string(from: date)
        return (amz, String(amz.prefix(8)))
    }

    static func hostHeader(_ url: URL) -> String {
        guard let host = url.host() else { return "" }
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            return "\(host):\(port)"
        }
        return host
    }

    /// Each path segment percent-encoded once (RFC 3986 unreserved kept).
    static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        var pairs: [(String, String)] = []
        for item in items {
            pairs.append((encode(decode(item.name)), encode(decode(item.value ?? ""))))
        }
        pairs.sort { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    public static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // `alphanumerics` includes non-ASCII letters; restrict to ASCII.
        return s.unicodeScalars.map { scalar -> String in
            scalar.isASCII && allowed.contains(scalar) ? String(scalar)
                : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    static func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
