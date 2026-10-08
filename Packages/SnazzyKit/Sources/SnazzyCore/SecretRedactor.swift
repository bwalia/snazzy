import Foundation

/// Hides likely secrets (API keys, tokens, passwords, private keys) in text
/// before it is sent to a cloud model.
public enum SecretRedactor {
    public struct Result: Equatable, Sendable {
        public var text: String
        /// Short descriptions of what was hidden, e.g. "GitHub token".
        public var hidden: [String]
    }

    static let patterns: [(String, String)] = [
        // To the END line, or to the end of the text when it was cut off before it.
        ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#),
        ("Anthropic key", #"sk-ant-[A-Za-z0-9_\-]{16,}"#),
        ("OpenAI-style key", #"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}"#),
        ("GitHub token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
        ("Slack token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        ("GitLab token", #"\bglpat-[A-Za-z0-9_\-]{20,}"#),
        ("npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
        ("Hugging Face token", #"\bhf_[A-Za-z0-9]{30,}\b"#),
        ("SendGrid key", #"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#),
        ("AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("Stripe key", #"\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}\b"#),
        ("JWT", #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
        ("password in URL", #"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)"#),
        // Authorization headers anywhere, last so known formats keep their names (curl -H "Authorization: Bearer …", HTTP logs).
        ("bearer token", #"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/\-]{16,}=*"#),
    ]

    /// `NAME=value` / `name: value` / `"name": "value"` lines whose name suggests a secret.
    static let assignment = #"(?im)^(\s*(?:export\s+)?["']?[A-Z0-9_.\-]*(?:SECRET|TOKEN|PASSWORD|PASSWD|PWD|API[_\-]?KEY|ACCESS[_\-]?KEY|PRIVATE[_\-]?KEY|CREDENTIAL|AUTH)[A-Z0-9_.\-]*["']?\s*[=:]\s*)(["']?)([^\s"'#]{4,})\2"#

    public static func redact(_ text: String) -> Result {
        var out = text
        var hidden: [String] = []
        for (label, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
            guard !matches.isEmpty else { continue }
            for m in matches.reversed() {
                guard let r = Range(m.range, in: out) else { continue }
                out.replaceSubrange(r, with: "[hidden \(label)]")
            }
            hidden += Array(repeating: label, count: matches.count)
        }
        if let regex = try? NSRegularExpression(pattern: assignment) {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
            for m in matches.reversed() {
                guard let value = Range(m.range(at: 3), in: out), !out[value].hasPrefix("[hidden") else { continue }
                out.replaceSubrange(value, with: "[hidden]")
                hidden.append("secret setting")
            }
        }
        return Result(text: out, hidden: hidden)
    }

    /// "Hid 2 likely secrets (GitHub token, secret setting)."
    public static func summary(_ hidden: [String]) -> String? {
        guard !hidden.isEmpty else { return nil }
        let kinds = Array(Set(hidden)).sorted().joined(separator: ", ")
        return "Hid \(hidden.count) likely secret\(hidden.count == 1 ? "" : "s") (\(kinds))."
    }
}
