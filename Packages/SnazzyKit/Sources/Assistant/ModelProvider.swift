import Foundation
import SnazzyCore

/// A chat model backend with streaming and tool calling.
public protocol ModelProvider: Sendable {
    var kind: ProviderKind { get }
    func listModels() async throws -> [ModelInfo]
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public extension ModelProvider {
    var isLocal: Bool { kind.isLocal }
}

enum HTTP {
    /// Starts a streaming request; throws a `ProviderError` for non-2xx with the
    /// response body's error message.
    static func lines(
        _ request: URLRequest, session: URLSession, errorMessage: (JSONValue) -> String?
    ) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw ProviderError.unreachable(describe(error, url: request.url))
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64_000 { break }
            }
            let parsed = try? JSONValue.parse(body)
            let message = parsed.flatMap(errorMessage) ?? String(decoding: body, as: UTF8.self)
            throw ProviderError.http(status: http.statusCode, message: message)
        }
        return bytes.lines
    }

    static func data(
        _ request: URLRequest, session: URLSession, errorMessage: (JSONValue) -> String?
    ) async throws -> JSONValue {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ProviderError.unreachable(describe(error, url: request.url))
        }
        let json = try? JSONValue.parse(data)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = json.flatMap(errorMessage) ?? String(decoding: data, as: UTF8.self)
            throw ProviderError.http(status: http.statusCode, message: message)
        }
        guard let json else { throw ProviderError.malformedResponse("invalid JSON") }
        return json
    }

    static func describe(_ error: URLError, url: URL?) -> String {
        let host = url?.host() ?? "server"
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "No network connection (\(host))."
        case .cannotConnectToHost, .cannotFindHost:
            return "Cannot connect to \(host). Is it running?"
        case .timedOut:
            return "\(host) timed out."
        default:
            return "\(host): \(error.localizedDescription)"
        }
    }
}
