import Foundation

/// Reads string fields out of JSON that is still streaming in (a tool call's
/// arguments), so the UI can show a file's content while it is written.
public enum PartialJSON {
    /// The (possibly incomplete) string value of `key` at the top level of a
    /// partial JSON object, or nil if the value hasn't started yet.
    public static func stringValue(forKey key: String, in text: String) -> String? {
        let chars = Array(text.unicodeScalars)
        var i = 0
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                // Read a string token; if it is a top-level key equal to `key`, read its value.
                let (token, end, closed) = readString(chars, from: i + 1)
                i = end
                guard closed else { return nil }
                if depth == 1, token == key {
                    var j = i
                    while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
                    guard j < chars.count, chars[j] == ":" else { continue }
                    j += 1
                    while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r" { j += 1 }
                    guard j < chars.count else { return nil }
                    guard chars[j] == "\"" else { return nil }
                    return readString(chars, from: j + 1).value
                }
                continue
            }
            if c == "{" || c == "[" { depth += 1 }
            if c == "}" || c == "]" { depth -= 1 }
            i += 1
        }
        return nil
    }

    /// Decodes a JSON string body starting after the opening quote. Returns the
    /// value so far, the index after the closing quote (or the end), and
    /// whether the string was closed.
    static func readString(_ chars: [Unicode.Scalar], from start: Int) -> (value: String, end: Int, closed: Bool) {
        var out = String.UnicodeScalarView()
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { return (String(out), i + 1, true) }
            if c == "\\" {
                guard i + 1 < chars.count else { break }  // escape split across fragments
                let e = chars[i + 1]
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    guard i + 5 < chars.count else { return (String(out), chars.count, false) }
                    let hex = String(String.UnicodeScalarView(chars[(i + 2)...(i + 5)]))
                    if let v = UInt32(hex, radix: 16) {
                        // Surrogate pairs: combine when both halves are present.
                        if (0xD800...0xDBFF).contains(v), i + 11 < chars.count, chars[i + 6] == "\\", chars[i + 7] == "u",
                           let low = UInt32(String(String.UnicodeScalarView(chars[(i + 8)...(i + 11)])), radix: 16),
                           (0xDC00...0xDFFF).contains(low),
                           let scalar = Unicode.Scalar(0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)) {
                            out.append(scalar)
                            i += 12
                            continue
                        }
                        if let scalar = Unicode.Scalar(v) { out.append(scalar) }
                    }
                    i += 6
                    continue
                default: out.append(e)  // \" \\ \/
                }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return (String(out), chars.count, false)
    }
}
