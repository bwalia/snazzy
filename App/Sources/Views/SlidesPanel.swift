import Builder
import SwiftUI

/// The Slides tab: present (and record) the open deck, find and organise your decks,
/// browse sample decks, or get decks from GitHub.
struct SlidesPanel: View {
    enum Mode: String, CaseIterable, Identifiable {
        case present = "Present"
        case library = "My Decks"
        case samples = "Samples"
        case github = "Get Decks"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let current = model.slidesMode ?? (model.builder.isDeckOpen ? .present : .samples)
        VStack(spacing: 0) {
            Picker("Slides", selection: Binding(get: { current }, set: { model.slidesMode = $0 })) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .padding(.top, 10)
            switch current {
            case .present: PresentView(showSamples: { model.slidesMode = .samples })
            case .samples: SampleGallery(opened: { model.slidesMode = .present })
            case .library: DeckLibraryView()
            case .github: DeckReposView()
            }
        }
    }
}

/// Example decks for different jobs and sectors. Opening one copies it into the
/// Builder, where the assistant can rewrite it with your own content.
struct SampleGallery: View {
    @Environment(AppModel.self) private var model
    var opened: () -> Void = {}
    @State private var sector: SampleDeck.Sector?
    @State private var error: String?

    private var samples: [SampleDeck] {
        SampleDeck.all.filter { sector == nil || $0.sector == sector }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sample decks").font(.headline)
                Text("Example decks by sector: lessons, pitches, training, board updates and more. Names and figures in the samples are made up, except Build & Ship AI. Open one, then ask the assistant to make it yours.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("All", symbol: "square.grid.2x2", selected: sector == nil) { sector = nil }
                        ForEach(SampleDeck.Sector.allCases) { s in
                            chip(s.rawValue, symbol: s.symbol, selected: sector == s) { sector = s }
                        }
                    }
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(samples) { deck in
                        SampleCard(deck: deck, open: { open(deck) }, usePrompt: { usePrompt(deck) })
                    }
                }
                .padding(12)
            }
        }
        .alert("Couldn't open the sample", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func chip(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func open(_ deck: SampleDeck) {
        do {
            try model.builder.openSample(deck)
            model.sidePanelTab = .builder
            opened()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func usePrompt(_ deck: SampleDeck) {
        model.chat.draft = deck.prompt
    }
}

private struct SampleCard: View {
    let deck: SampleDeck
    let open: () -> Void
    let usePrompt: () -> Void
    @State private var showOutline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SlideThumbnail(deck: deck)
            Label(deck.sector.rawValue, systemImage: deck.sector.symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(Color(hex: deck.accent))
            Text(deck.title).font(.headline)
            Text(deck.useCase).font(.callout)
            Text("\(deck.audience) · about \(deck.minutes) min · \(deck.slides.count) slides")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(deck.setup, id: \.self) { tip in
                    Label(tip, systemImage: "video").font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Slides", isExpanded: $showOutline) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(deck.slides.enumerated()), id: \.offset) { i, s in
                        Text("\(i + 1). \(s.heading)").font(.caption).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.caption)
            HStack {
                Button("Open in Builder", action: open).buttonStyle(.borderedProminent)
                Button("Use the prompt", action: usePrompt)
                    .help("Puts “\(deck.prompt)” in the chat box, ready to edit and send")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A small drawing of the title slide in the deck's colours.
private struct SlideThumbnail: View {
    let deck: SampleDeck

    var body: some View {
        let accent = Color(hex: deck.accent)
        ZStack(alignment: .leading) {
            Color(red: 0.06, green: 0.08, blue: 0.13)
            VStack(alignment: .leading, spacing: 6) {
                Text(deck.slides.first?.heading ?? deck.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .leading, endPoint: .trailing))
                    .lineLimit(2)
                if let subtitle = deck.slides.first?.items.first {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Capsule().fill(accent).frame(width: 36, height: 3)
            }
            .padding(.horizontal, 18)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension Color {
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
