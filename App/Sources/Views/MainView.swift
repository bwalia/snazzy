import Assistant
import SnazzyCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ConversationList()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            HSplitView {
                ChatView()
                    .frame(minWidth: 380, idealWidth: 460, maxWidth: 760)
                SidePanel()
                    .frame(minWidth: 420)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { RecordingControls() }
            }
            .overlay(alignment: .bottom) { RecordingSavedBanner() }
        }
    }
}

/// Saved conversations.
struct ConversationList: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var newTitle = ""

    var body: some View {
        let chat = model.chat!
        List(selection: Binding(get: { chat.conversation.id }, set: { id in if let id { chat.open(id) } })) {
            if chat.conversation.messages.isEmpty {
                Label("New conversation", systemImage: "square.and.pencil").tag(chat.conversation.id)
            }
            ForEach(chat.conversations) { c in
                VStack(alignment: .leading, spacing: 2) {
                    if renaming == c.id {
                        TextField("Title", text: $newTitle)
                            .onSubmit { chat.rename(c.id, to: newTitle); renaming = nil }
                    } else {
                        Text(c.title).lineLimit(2)
                    }
                    Text(c.updated.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
                }
                .tag(c.id)
                .contextMenu {
                    Button("Rename") { newTitle = c.title; renaming = c.id }
                    Button("Delete", role: .destructive) { confirmDelete(c) }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { chat.newConversation() } label: { Label("New Conversation", systemImage: "square.and.pencil") }
                    .disabled(chat.isRunning)
                    .help("New conversation (⌘N)")
            }
        }
    }

    private func confirmDelete(_ c: ConversationSummary) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(c.title)”?"
        alert.informativeText = "The conversation is removed permanently."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.chat.delete(c.id) }
    }
}

/// Right-hand panel.
struct SidePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case builder = "Builder"
        case sources = "Sources & Preview"
        case slides = "Slides"
        case recordings = "Recordings"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Panel", selection: $model.sidePanelTab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            Group {
                switch model.sidePanelTab {
                case .builder:
                    BuilderPanel()
                case .sources:
                    SourcesPanel()
                case .slides:
                    ContentUnavailableView(
                        "No slides yet", systemImage: "rectangle.on.rectangle",
                        description: Text("Native slides arrive in phase 6. Ask the assistant to build an HTML presentation in the Builder now."))
                case .recordings:
                    RecordingsPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }
}
