import Foundation
import SnazzyCore

/// Some local models (e.g. Qwen3-Coder through Ollama) sometimes write a tool
/// call into their reply as text instead of returning it as a tool call. This
/// finds those calls so they still run, and removes them from the text.
///
/// Understood forms:
///   <tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>
///   <tool_call>{"name": "NAME", "arguments": {...}}</tool_call>
///   <function=NAME>…</function>  (without the outer tool_call tags)
public enum TextToolCalls {
    public static func extract(from text: String) -> (text: String, calls: [(name: String, arguments: JSONValue)])? {
        guard text.contains("<function=") || text.contains("<tool_call>") else { return nil }
        var calls: [(String, JSONValue)] = []
        var cleaned = text

        // XML style: <function=NAME> … </function>
        let fn = try! NSRegularExpression(pattern: #"<function=([A-Za-z0-9_\-]+)>(.*?)</function>"#, options: [.dotMatchesLineSeparators])
        let param = try! NSRegularExpression(pattern: #"<parameter=([A-Za-z0-9_\-]+)>(.*?)</parameter>"#, options: [.dotMatchesLineSeparators])
        let ns = text as NSString
        for m in fn.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2)) as NSString
            var args: [String: JSONValue] = [:]
            for p in param.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                let key = body.substring(with: p.range(at: 1))
                let raw = body.substring(with: p.range(at: 2)).trimmingCharacters(in: .newlines)
                args[key] = value(raw)
            }
            calls.append((name, .object(args)))
        }

        // JSON style inside <tool_call> … </tool_call>
        if calls.isEmpty {
            let tc = try! NSRegularExpression(pattern: #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#, options: [.dotMatchesLineSeparators])
            for m in tc.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let json = try? JSONValue.parse(Data(ns.substring(with: m.range(at: 1)).utf8)),
                      let name = json["name"]?.stringValue else { continue }
                var args = json["arguments"] ?? json["parameters"] ?? [:]
                if case .string(let s) = args, let parsed = try? JSONValue.parse(Data(s.utf8)) { args = parsed }
                calls.append((name, args))
            }
        }
        guard !calls.isEmpty else { return nil }

        // Remove the call markup (and empty tool_call wrappers) from the visible text.
        for pattern in [#"<tool_call>.*?</tool_call>"#, #"<function=.*?</function>"#, #"</?tool_call>"#] {
            let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            cleaned = re.stringByReplacingMatches(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length), withTemplate: "")
        }
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }

    /// A reply with a tool-call tag but no usable call (the model started one and
    /// stopped): drop the tags and anything unfinished after an opening one.
    public static func withoutStrayMarkup(_ text: String) -> String {
        guard text.contains("<tool_call>") || text.contains("</tool_call>") || text.contains("<function=") else { return text }
        var t = text
        if let open = t.range(of: "<tool_call>", options: .backwards), t.range(of: "</tool_call>", range: open.upperBound..<t.endIndex) == nil {
            t = String(t[..<open.lowerBound])
        }
        if let open = t.range(of: "<function=", options: .backwards), t.range(of: "</function>", range: open.upperBound..<t.endIndex) == nil {
            t = String(t[..<open.lowerBound])
        }
        t = t.replacingOccurrences(of: #"</?tool_call>"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parameter text → JSON (numbers, booleans, arrays and objects stay typed).
    static func value(_ raw: String) -> JSONValue {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, "[{\"-0123456789tfn".contains(first), let v = try? JSONValue.parse(Data(t.utf8)) { return v }
        return .string(raw)
    }
}
