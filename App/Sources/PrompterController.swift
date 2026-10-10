import Foundation
import Observation
import Remote

/// The teleprompter: scrolls the current slide's speaker notes at a reading
/// speed. Played and paused from the Present view, the iPhone/iPad remote or
/// the watch; pausing the recording pauses it too. The position is a fraction
/// of the notes (0…1), so every screen shows the same place at any font size.
@MainActor @Observable
final class PrompterController {
    private(set) var running = false
    private(set) var wordsPerMinute: Double {
        didSet { UserDefaults.standard.set(wordsPerMinute, forKey: "SnazzyPro.prompterWPM") }
    }
    /// Position at `anchor`; it moves on from there while running.
    private(set) var anchorProgress = 0.0
    private(set) var anchor = Date()
    /// The slide whose notes are showing.
    @ObservationIgnored private var slide = -1
    /// Paused because the recording paused, so resuming it resumes this.
    @ObservationIgnored private var pausedByRecording = false
    @ObservationIgnored private var endTimer: Task<Void, Never>?
    /// Words in the current notes (set by `show`).
    private(set) var words = 0

    init() {
        let saved = UserDefaults.standard.double(forKey: "SnazzyPro.prompterWPM")
        wordsPerMinute = PrompterState.speeds.contains(saved) ? saved : 140
    }

    var state: PrompterState { PrompterState(running: running, wordsPerMinute: wordsPerMinute, progress: progress()) }
    /// The state as of `anchor`, for views that keep it moving themselves.
    var anchored: PrompterState { PrompterState(running: running, wordsPerMinute: wordsPerMinute, progress: anchorProgress) }

    func progress(at date: Date = Date()) -> Double {
        PrompterState(running: running, wordsPerMinute: wordsPerMinute, progress: anchorProgress)
            .progress(after: date.timeIntervalSince(anchor), words: words)
    }

    /// The notes on screen changed (another slide or deck): back to the top,
    /// still playing if it was.
    func show(slide index: Int, notes: String?) {
        let count = PrompterState.words(in: notes)
        guard index != slide || count != words else { return }
        slide = index
        words = count
        move(to: 0)
    }

    func perform(_ action: PrompterAction) {
        switch action {
        case .play: setRunning(true)
        case .pause: setRunning(false)
        case .toggle: setRunning(!running)
        case .faster: setSpeed(wordsPerMinute + PrompterState.step)
        case .slower: setSpeed(wordsPerMinute - PrompterState.step)
        case .restart: move(to: 0)
        case .seek(let p): move(to: p)
        }
    }

    func setRunning(_ on: Bool) {
        pausedByRecording = false
        guard on != running else { return }
        rebase()
        // Playing from the end starts again from the top.
        if on, anchorProgress >= 1 { anchorProgress = 0 }
        running = on
        scheduleEnd()
    }

    func setSpeed(_ wpm: Double) {
        rebase()
        wordsPerMinute = min(PrompterState.speeds.upperBound, max(PrompterState.speeds.lowerBound, wpm))
        scheduleEnd()
    }

    func move(to p: Double) {
        anchorProgress = min(1, max(0, p.isFinite ? p : 0))
        anchor = Date()
        scheduleEnd()
    }

    // MARK: Recording

    func recordingPaused() {
        guard running else { return }
        setRunning(false)
        pausedByRecording = true
    }

    func recordingResumed() {
        guard pausedByRecording else { return }
        setRunning(true)
    }

    // MARK: Private

    private func rebase() {
        anchorProgress = progress()
        anchor = Date()
    }

    /// Stops at the end of the notes, so playing again starts over.
    private func scheduleEnd() {
        endTimer?.cancel()
        guard running, words > 0 else { return }
        let seconds = (1 - progress()) * Double(words) * 60 / wordsPerMinute
        endTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
            guard !Task.isCancelled, let self else { return }
            self.anchorProgress = 1
            self.anchor = Date()
            self.running = false
        }
    }
}
