import Foundation
import Remote
import WatchConnectivity

/// Relays between the Apple Watch and the Mac: the watch's commands go to the
/// Mac over this app's link, and the Mac's status goes back to the watch.
final class WatchRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Runs a command on the Mac (set by `RemoteModel`).
    @MainActor var perform: ((RemoteCommand) async -> (ok: Bool, message: String?))?
    /// The state to show right now (set by `RemoteModel`).
    @MainActor var current: (() -> WatchState)?

    private let lock = NSLock()
    private var lastSent: WatchState?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }  // e.g. iPad
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends the state to the watch when it changed (or every 10 seconds, to
    /// correct the watch's timer).
    func publish(_ state: WatchState) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let send = lock.withLock { () -> Bool in
            if let last = lastSent, last.matches(state), state.sentAt.timeIntervalSince(last.sentAt) < 10 { return false }
            lastSent = state
            return true
        }
        guard send, let data = WatchLink.encode(state) else { return }
        let payload = [WatchLink.stateKey: data]
        // Latest state for when the watch app opens; a message when it's open now.
        try? session.updateApplicationContext(payload)
        if session.isReachable { session.sendMessage(payload, replyHandler: nil) }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = Reply(replyHandler)
        let command = WatchLink.decode(RemoteCommand.self, message[WatchLink.commandKey])
        let hello = message[WatchLink.helloKey] != nil
        Task { @MainActor in
            if let command {
                guard WatchLink.allows(command), let perform = self.perform else {
                    reply.send([WatchLink.okKey: false, WatchLink.messageKey: "The watch can't do that."])
                    return
                }
                let (ok, text) = await perform(command)
                var out: [String: Any] = [WatchLink.okKey: ok]
                if let text { out[WatchLink.messageKey] = text }
                reply.send(out)
            } else if hello, let state = self.current?(), let data = WatchLink.encode(state) {
                reply.send([WatchLink.stateKey: data])
            } else {
                reply.send([:])
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.lock.withLock { self.lastSent = nil }
            if let state = self.current?() { self.publish(state) }
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lock.withLock { self.lastSent = nil }
            if let state = self.current?() { self.publish(state) }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another watch: activate again for the new one.
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

/// WatchConnectivity's reply handler, carried across to the main actor.
private struct Reply: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ value: [String: Any]) { handler(value) }
}
