import Builder
import SwiftUI

/// Make or edit a slide deck without AI: a title, a colour, and slides in the
/// house layouts with speaker notes. Shared by the Mac and iPad apps.
struct DeckEditorView: View {
    @State var outline: DeckOutline
    let isNew: Bool
    var onSave: (DeckOutline) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Deck") {
                    TextField("Title", text: $outline.title)
                    HStack(spacing: 10) {
                        Text("Colour")
                        Spacer()
                        ForEach(DeckOutline.accents, id: \.self) { hex in
                            Button {
                                outline.accent = hex
                            } label: {
                                Circle().fill(Color(hexString: hex)).frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: outline.accent == hex ? 2.5 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(hex)")
                        }
                    }
                }
                ForEach($outline.slides.indices, id: \.self) { i in
                    Section {
                        Picker("Layout", selection: $outline.slides[i].layout) {
                            ForEach(SampleDeck.Slide.Layout.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        TextField(outline.slides[i].layout == .quote ? "Quote" : "Heading", text: $outline.slides[i].heading, axis: .vertical)
                        TextField(outline.slides[i].layout.itemsHint, text: Binding(
                            get: { outline.slides[i].items.joined(separator: "\n") },
                            set: { outline.slides[i].items = $0.components(separatedBy: "\n") }), axis: .vertical)
                            .lineLimit(2...10)
                        TextField("Speaker notes", text: $outline.slides[i].notes, axis: .vertical)
                            .lineLimit(1...6)
                    } header: {
                        HStack {
                            Text("Slide \(i + 1)")
                            Spacer()
                            Button { move(i, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(i == 0).accessibilityLabel("Move up")
                            Button { move(i, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(i == outline.slides.count - 1).accessibilityLabel("Move down")
                            Button(role: .destructive) { outline.slides.remove(at: i) } label: { Image(systemName: "trash") }
                                .disabled(outline.slides.count == 1).accessibilityLabel("Delete slide")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Section {
                    Menu {
                        ForEach(SampleDeck.Slide.Layout.allCases, id: \.self) { layout in
                            Button(layout.displayName) { outline.slides.append(.init(layout, "", [])) }
                        }
                    } label: { Label("Add a Slide", systemImage: "plus.rectangle.on.rectangle") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Deck" : "Edit Slides")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { onSave(cleaned) }
                        .disabled(outline.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
    }

    /// Drops empty lines from the slide items before saving.
    private var cleaned: DeckOutline {
        var o = outline
        for i in o.slides.indices { o.slides[i].items = o.slides[i].items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return o
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard outline.slides.indices.contains(j) else { return }
        outline.slides.swapAt(i, j)
    }
}

extension Color {
    init(hexString: String) {
        let v = UInt32(hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
