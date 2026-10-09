import Foundation

/// Short spoken commands Voice Mode runs straight away, without the AI (fast,
/// and they work with no model set up). Anything else goes to the assistant.
public enum VoiceCommand: Equatable, Sendable {
    case nextSlide
    case previousSlide
    case goToSlide(Int)  // 1-based, as people say it
    case lastSlide
    case startRecording
    case stopRecording
    case pauseRecording
    case resumeRecording
    case startPrompter
    case pausePrompter
    /// "Stop listening": leave Voice Mode.
    case stopListening
}

public enum VoiceCommands {
    public static let defaultWakeWord = "Snazzy"

    /// The wake word in use: an empty setting doesn't turn the check off.
    public static func wakeWord(_ setting: String) -> String {
        let w = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty ? defaultWakeWord : w
    }

    /// The text after the wake word, if the utterance starts with it
    /// ("Snazzy, next slide", "Hey Snazzy next slide", "OK Snazzy…"). Nil if it doesn't.
    public static func afterWakeWord(_ text: String, wakeWord: String = defaultWakeWord) -> String? {
        let greetings: Set<String> = ["hey", "ok", "okay", "hi"]
        var words = normalize(text).split(separator: " ").map(String.init)
        var wakeWords = normalize(Self.wakeWord(wakeWord)).split(separator: " ").map(String.init)
        if let first = words.first, greetings.contains(first) { words.removeFirst() }
        if wakeWords.count > 1, let first = wakeWords.first, greetings.contains(first) { wakeWords.removeFirst() }
        // Recognisers sometimes spell it differently ("snazzie", "snazy").
        guard !wakeWords.isEmpty, words.count >= wakeWords.count,
              zip(words, wakeWords).allSatisfy({ similar($0, $1) }) else { return nil }
        words.removeFirst(wakeWords.count)
        return words.joined(separator: " ")
    }

    /// A built-in command, if the whole utterance is one. Longer sentences go to the assistant.
    public static func parse(_ text: String) -> VoiceCommand? {
        var words = normalize(text).split(separator: " ").map(String.init)
        let filler: Set<String> = ["please", "now", "the", "a", "can", "you", "could", "go", "to", "lets", "let's", "and", "thanks", "thank"]
        words.removeAll { filler.contains($0) }
        let s = words.joined(separator: " ")
        guard !s.isEmpty, words.count <= 5 else { return nil }
        switch s {
        case "next", "next slide", "forward", "slide forward", "advance": return .nextSlide
        case "back", "previous", "previous slide", "slide back", "back one slide": return .previousSlide
        case "last slide", "final slide": return .lastSlide
        case "start recording", "record", "begin recording", "start record", "start the recording": return .startRecording
        case "stop recording", "end recording", "finish recording", "stop record", "stop and save": return .stopRecording
        case "pause recording", "pause", "hold recording": return .pauseRecording
        case "resume recording", "resume", "continue recording", "carry on": return .resumeRecording
        case "start prompter", "start teleprompter", "scroll prompter", "start scrolling": return .startPrompter
        case "pause prompter", "stop prompter", "pause teleprompter", "stop scrolling": return .pausePrompter
        case "stop listening", "voice mode off", "stop voice mode", "goodbye", "that's all", "thats all": return .stopListening
        default: break
        }
        // "slide 5", "first slide", "slide number three"; "go to slide to" is slide two.
        let heard = normalize(text).split(separator: " ").map(String.init)
        if let i = heard.lastIndex(of: "slide") {
            let rest = heard[(i + 1)...].filter { $0 != "number" }
            if rest.count == 1, let n = number(rest[rest.startIndex]) { return .goToSlide(n) }
        }
        let slideWords = words.filter { $0 != "slide" && $0 != "number" }
        if words.contains("slide"), slideWords.count == 1, let n = number(slideWords[0]) { return .goToSlide(n) }
        if words == ["first"] || s == "first slide" || s == "beginning" { return .goToSlide(1) }
        return nil
    }

    /// Chat Markdown as something worth saying out loud: no code, links read
    /// as their words, no list markers or emphasis, and not too long.
    public static func speakable(_ markdown: String, limit: Int = 600) -> String {
        var lines: [String] = []
        var inCode = false
        var skippedCode = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inCode.toggle()
                if inCode { skippedCode = true }
                continue
            }
            if inCode || line.hasPrefix("|") || line == "---" { continue }
            var l = line
            for prefix in ["#### ", "### ", "## ", "# ", "> ", "- ", "* ", "• "] where l.hasPrefix(prefix) { l.removeFirst(prefix.count) }
            l = l.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: #"[*_~]{1,3}"#, with: "", options: .regularExpression)
            if !l.isEmpty { lines.append(l) }
        }
        var text = lines.joined(separator: " ")
        if skippedCode { text += (text.isEmpty ? "" : " ") + "The code is in the chat." }
        guard text.count > limit else { return text }
        // Cut at the end of a sentence.
        let cut = String(text.prefix(limit))
        if let end = cut.range(of: #"[.!?](?=[^.!?]*$)"#, options: .regularExpression) {
            return String(cut[..<end.upperBound]) + " There's more in the chat."
        }
        return cut + "… There's more in the chat."
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// Spelled differently but said the same ("snazzie", "snazy" for "snazzy");
    /// a different word isn't ("snappy"). Long wake words allow one slip.
    static func similar(_ a: String, _ b: String) -> Bool {
        let (x, y) = (sound(a), sound(b))
        if x == y { return true }
        return y.count >= 7 && x.first == y.first && distance(x, y) <= 1
    }

    /// Doubled letters as one, and an "ie"/"ey"/"i" ending as "y".
    static func sound(_ word: String) -> String {
        var out = ""
        for c in word where c != out.last { out.append(c) }
        for ending in ["ie", "ey", "i"] where out.count > ending.count + 2 && out.hasSuffix(ending) {
            return String(out.dropLast(ending.count)) + "y"
        }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...max(1, b.count) where !b.isEmpty {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    static func number(_ w: String) -> Int? {
        if let n = Int(w), n > 0 { return n }
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        if let i = words.firstIndex(of: w) { return i + 1 }
        if let i = ordinals.firstIndex(of: w) { return i + 1 }
        if w == "to" || w == "too" { return 2 }  // "slide two" heard as "slide to"
        if w == "for" { return 4 }
        return nil
    }
}
