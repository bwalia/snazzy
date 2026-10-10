import Foundation
import Network

/// One encrypted connection: sends and receives `RemoteMessage`s.
public final class RemoteLink: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting, ready, closed(String?)
    }

    public let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var reader = RemoteFrame.Reader()
    private var closed = false

    public var onMessage: (@Sendable (RemoteMessage) -> Void)?
    public var onState: (@Sendable (State) -> Void)?

    public init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState?(.ready)
            case .failed(let e):
                self.finish(Self.describe(e))
            case .waiting(let e):
                // TLS failures (wrong key) and unreachable hosts land here.
                // Don't leave the connection waiting to retry on its own.
                self.finish(Self.describe(e))
                self.connection.cancel()
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    public func send(_ message: RemoteMessage) {
        guard let data = try? RemoteFrame.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func close(_ reason: String? = nil) {
        if let reason { send(.bye(reason)) }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let messages = try self.lock.withLock { try self.reader.append(data) }
                    messages.forEach { self.onMessage?($0) }
                } catch {
                    self.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                self.finish(error.map(Self.describe))
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func finish(_ reason: String?) {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        // A connection left waiting or failed would otherwise linger (one per retry).
        connection.cancel()
        onState?(.closed(reason))
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .tls(let status):
            // errSSLBadRecordMac / unknown PSK identity: the key doesn't match.
            return status == -9846 || status == -9864 ? "This device isn't paired with that Mac (or was removed). Pair again." : "Secure connection failed (\(status))."
        case .posix(let code) where code == .ECONNREFUSED:
            return "Snazzy Pro isn't accepting connections on that Mac."
        default:
            return error.localizedDescription
        }
    }
}
