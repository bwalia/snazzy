import SwiftUI

/// Speaker notes that scroll with the teleprompter, on the Mac and on devices.
/// Position 1 brings the last lines up to the top part of the view, where
/// you read. Drag to move through the notes.
public struct PrompterScroller: View {
    let text: String
    let fontSize: Double
    let state: PrompterState
    /// When `state.progress` was measured.
    let since: Date
    let onSeek: (Double) -> Void

    @State private var textHeight: CGFloat = 0
    @State private var drag: (start: Double, now: Double)?
    /// Where a drag ended, shown until the new position comes back.
    @State private var held: Double?

    public init(text: String, fontSize: Double, state: PrompterState, since: Date, onSeek: @escaping (Double) -> Void) {
        self.text = text
        self.fontSize = fontSize
        self.state = state
        self.since = since
        self.onSeek = onSeek
    }

    public var body: some View {
        let words = PrompterState.words(in: text)
        GeometryReader { g in
            let range = max(0, textHeight - g.size.height * 0.4)
            TimelineView(.animation(paused: !state.running || drag != nil || held != nil)) { context in
                let p = drag?.now ?? held ?? state.progress(after: context.date.timeIntervalSince(since), words: words)
                Text(text)
                    .font(.system(size: fontSize, weight: .medium))
                    .lineSpacing(fontSize * 0.25)
                    .frame(width: g.size.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                    .offset(y: -p * range)
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        let start = drag?.start ?? held ?? state.progress(after: Date().timeIntervalSince(since), words: words)
                        let now = range > 0 ? start - v.translation.height / range : start
                        drag = (start, min(1, max(0, now)))
                    }
                    .onEnded { _ in
                        if let now = drag?.now {
                            held = now
                            onSeek(now)
                        }
                        drag = nil
                    }
            )
            .onChange(of: state) { held = nil }
            .task(id: held) {
                // Don't hold on forever if the answer never comes.
                guard held != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { held = nil }
            }
        }
    }
}
