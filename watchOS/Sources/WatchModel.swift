import Foundation
import Observation
import Remote
import WatchConnectivity
import WatchKit

/// The watch side: the Mac's status relayed by the iPhone app, and commands
/// sent back through it.
@MainActor @Observable
final class WatchModel: NSObject {
    private(set) var state: WatchState?
    private(set) var phoneReachable = false
    private(set) var busy = false
    private(set) var lastResult: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var status: RemoteStatus? { state?.problem == nil ? state?.status : nil }

    /// Why the controls aren't available, if they aren't.
    var problem: String? {
        if !phoneReachable && state == nil { return "Open Snazzy Pro on your iPhone." }
        guard let state else { return "Waiting for your iPhone…" }
        return state.problem ?? (state.status == nil ? "Waiting for the Mac…" : nil)
    }

    func send(_ command: RemoteCommand) {
        guard let data = WatchLink.encode(command) else { return }
        let session = WCSession.default
        guard session.isReachable else {
            fail("Open Snazzy Pro on your iPhone.")
            return
        }
        busy = true
        lastResult = nil
        // WatchConnectivity calls these on its own queue, so they mustn't be main-actor closures.
        session.sendMessage([WatchLink.commandKey: data], replyHandler: { @Sendable [weak self] reply in
            let ok = reply[WatchLink.okKey] as? Bool ?? false
            let message = reply[WatchLink.messageKey] as? String
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                if ok { WKInterfaceDevice.current().play(.click) } else { self.fail(message ?? "That didn't work.") }
            }
        }, errorHandler: { @Sendable [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                self?.busy = false
                self?.fail(message)
            }
        })
    }

    /// Asks the iPhone for its current state (when the app opens).
    func refresh() {
        let session = WCSession.default
        if let s = WatchLink.decode(WatchState.self, session.receivedApplicationContext[WatchLink.stateKey]) { apply(s) }
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([WatchLink.helloKey: true], replyHandler: { @Sendable [weak self] reply in
            guard let s = WatchLink.decode(WatchState.self, reply[WatchLink.stateKey]) else { return }
            Task { @MainActor in self?.apply(s) }
        }, errorHandler: nil)
    }

    private func fail(_ message: String) {
        lastResult = message
        WKInterfaceDevice.current().play(.failure)
    }

    private func apply(_ new: WatchState) {
        // Ignore older state arriving late (application context vs. messages).
        if let old = state, new.sentAt < old.sentAt { return }
        if let before = state?.status, let after = new.status, new.problem == nil {
            if before.recording != "recording" && after.recording == "recording" { WKInterfaceDevice.current().play(.start) }
            if before.isRecording && !after.isRecording { WKInterfaceDevice.current().play(.stop) }
        }
        state = new
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachable = reachable
            self.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachable = reachable
            if reachable { self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let s = WatchLink.decode(WatchState.self, message[WatchLink.stateKey]) else { return }
        Task { @MainActor in self.apply(s) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let s = WatchLink.decode(WatchState.self, applicationContext[WatchLink.stateKey]) else { return }
        Task { @MainActor in self.apply(s) }
    }
}
