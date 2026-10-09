import Testing
@testable import SnazzyCore

@Suite struct VoiceCommandTests {
    @Test func builtInCommands() {
        #expect(VoiceCommands.parse("Next slide.") == .nextSlide)
        #expect(VoiceCommands.parse("Next slide, please") == .nextSlide)
        #expect(VoiceCommands.parse("Go back") == .previousSlide)
        #expect(VoiceCommands.parse("Start recording") == .startRecording)
        #expect(VoiceCommands.parse("Can you stop recording") == .stopRecording)
        #expect(VoiceCommands.parse("Pause") == .pauseRecording)
        #expect(VoiceCommands.parse("Go to slide 5") == .goToSlide(5))
        #expect(VoiceCommands.parse("slide number three") == .goToSlide(3))
        #expect(VoiceCommands.parse("first slide") == .goToSlide(1))
        #expect(VoiceCommands.parse("Start the teleprompter") == .startPrompter)
        #expect(VoiceCommands.parse("Stop listening") == .stopListening)
    }

    @Test func sentencesGoToTheAssistant() {
        #expect(VoiceCommands.parse("Make the next slide about our pricing") == nil)
        #expect(VoiceCommands.parse("Record a short intro for the deck about recycling please") == nil)
        #expect(VoiceCommands.parse("") == nil)
    }

    @Test func wakeWord() {
        #expect(VoiceCommands.afterWakeWord("Snazzy, next slide") == "next slide")
        #expect(VoiceCommands.afterWakeWord("Hey Snazzy next slide") == "next slide")
        #expect(VoiceCommands.afterWakeWord("Snazzie stop recording") == "stop recording")
        #expect(VoiceCommands.afterWakeWord("So the next slide shows our results") == nil)
        #expect(VoiceCommands.afterWakeWord("next slide", wakeWord: "") == "next slide")
    }

    @Test func speakableText() {
        let md = "## Done\nI made **3 slides**:\n- Title\n- [Results](https://x.y)\n```html\n<p>hi</p>\n```"
        #expect(VoiceCommands.speakable(md) == "Done I made 3 slides: Title Results The code is in the chat.")
        let long = String(repeating: "This is a sentence. ", count: 60)
        let s = VoiceCommands.speakable(long, limit: 100)
        #expect(s.hasSuffix("There's more in the chat.") && s.count < 140)
    }
}
