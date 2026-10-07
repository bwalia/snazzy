import CaptureEngine
import Foundation
import SnazzyCore
import Testing
@testable import Broadcast

@Suite struct BroadcastTests {
    @Test func platformsHaveSecureIngest() {
        for p in BroadcastPlatform.allCases where p != .custom {
            #expect(p.defaultServer.hasPrefix("rtmps://"), "\(p)")
            #expect(p.keychainAccount == "broadcast.\(p.rawValue)")
        }
    }

    /// Streams to a local RTMP server when SNAZZY_RTMP_TEST is set to its URL
    /// (e.g. `ffmpeg -listen 1 -i rtmp://127.0.0.1:19350/live/testkey -c copy out.flv`).
    @Test func streamsToLocalServer() async throws {
        guard let server = ProcessInfo.processInfo.environment["SNAZZY_RTMP_TEST"] else { return }
        let b = Broadcaster()
        b.setSource(screen: nil, camera: nil, spec: CompositeSpec(layout: InsetLayout(), profile: .defaults(for: .camera)))
        try await b.start(server: server, key: "testkey", quality: .hd720, micID: "none")
        try await Task.sleep(for: .seconds(4))
        await b.stop()
        #expect(b.framesSent > 60)
    }
}
