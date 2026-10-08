import SwiftUI

/// Snazzy Pro for iPhone and iPad: a remote for Snazzy Pro on your Mac.
@main
struct SnazzyRemoteApp: App {
    @State private var model = RemoteModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.42, green: 0.36, blue: 1))
                // A pairing link from the Camera app (snazzypro://pair?...).
                .onOpenURL { model.pair(with: $0) }
                .onChange(of: phase) { _, p in
                    if p == .active { model.start() }
                }
        }
    }
}

struct RootView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if model.hosts.isEmpty && !model.isConnected {
            PairView()
        } else {
            RemoteView()
        }
    }
}
