import Foundation
import Testing
@testable import CaptureEngine

@Suite struct CaptionsTests {
    @Test func timestamps() {
        #expect(Captions.timestamp(3725.0456, separator: ",") == "01:02:05,046")
        #expect(Captions.timestamp(0, separator: ".") == "00:00:00.000")
    }

    @Test func breaksOnPausesSentencesAndLength() {
        let words = [
            TimedWord("Welcome", 0.0, 0.4), TimedWord("to", 0.45, 0.6), TimedWord("the", 0.6, 0.7), TimedWord("Q3", 0.75, 1.0),
            TimedWord("review.", 1.0, 1.5),
            // Long pause → new cue.
            TimedWord("Deploys", 3.0, 3.4), TimedWord("are", 3.4, 3.5), TimedWord("up", 3.5, 3.7), TimedWord("forty", 3.7, 4.0), TimedWord("percent", 4.0, 4.5),
        ]
        let cues = Captions.cues(from: words)
        #expect(cues.map(\.text) == ["Welcome to the Q3 review.", "Deploys are up forty percent"])
        #expect(cues[0].start == 0 && cues[0].end == 1.5)
        #expect(cues[1].start == 3.0)
    }

    @Test func longCuesWrapAndSplit() {
        let words = (0..<40).map { TimedWord("word\($0)", Double($0) * 0.3, Double($0) * 0.3 + 0.25) }
        let cues = Captions.cues(from: words)
        #expect(cues.count > 1)
        for cue in cues {
            #expect(cue.text.replacingOccurrences(of: "\n", with: " ").count <= Captions.maxCharacters)
            #expect(cue.end - cue.start <= Captions.maxDuration + 0.01)
            #expect(cue.text.split(separator: "\n").count <= 2)
        }
        for (a, b) in zip(cues, cues.dropFirst()) { #expect(a.end <= b.start) }
    }

    @Test func srtAndVtt() {
        let cues = [CaptionCue(start: 0, end: 1.5, text: "Hello there."), CaptionCue(start: 2, end: 3.25, text: "Second")]
        #expect(Captions.srt(cues) == "1\n00:00:00,000 --> 00:00:01,500\nHello there.\n\n2\n00:00:02,000 --> 00:00:03,250\nSecond\n")
        #expect(Captions.vtt(cues).hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello there.\n"))
        #expect(Captions.timedTranscript(cues) == "[00:00] Hello there. Second")
    }
}
