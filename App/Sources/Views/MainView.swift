import SnazzyCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HSplitView {
            ChatView()
                .frame(minWidth: 380, idealWidth: 460, maxWidth: 720)
            SidePanel()
                .frame(minWidth: 420)
        }
    }
}

/// Right-hand panel. Tabs are filled in by later phases.
struct SidePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case slides = "Slides"
        case sources = "Sources & Preview"
        case timeline = "Timeline"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .slides

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            Group {
                switch tab {
                case .slides:
                    ContentUnavailableView(
                        "No slides yet", systemImage: "rectangle.on.rectangle",
                        description: Text("Slides you plan with the assistant appear here (phase 5)."))
                case .sources:
                    ContentUnavailableView(
                        "Sources & preview", systemImage: "web.camera",
                        description: Text("Cameras, mics, displays and live previews arrive in phase 2."))
                case .timeline:
                    ContentUnavailableView(
                        "Timeline", systemImage: "timeline.selection",
                        description: Text("Recordings, chapters and trimming arrive in phases 3 and 6."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }
}
