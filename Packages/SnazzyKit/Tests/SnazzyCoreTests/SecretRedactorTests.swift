import Testing
@testable import SnazzyCore

@Suite struct SecretRedactorTests {
    // Fake tokens are assembled at runtime so secret scanners don't flag this file.
    let github = "gh" + "p_" + String(repeating: "a1B2", count: 9)
    let aws = "AK" + "IA" + "IOSFODNN7EXAMPLE"
    let anthropic = "sk-" + "ant-" + "api03-" + String(repeating: "x9", count: 12)

    @Test func hidesKnownTokenFormats() {
        let text = """
            curl -H "Authorization: Bearer \(github)" https://api.github.com
            aws configure set aws_access_key_id \(aws)
            ANTHROPIC_API_KEY=\(anthropic)
            postgres://admin:hunter2@db.internal:5432/app
            """
        let r = SecretRedactor.redact(text)
        #expect(!r.text.contains(github))
        #expect(!r.text.contains(aws))
        #expect(!r.text.contains(anthropic))
        #expect(!r.text.contains("hunter2"))
        #expect(r.text.contains("https://api.github.com"))
        #expect(r.text.contains("db.internal:5432"))
        #expect(r.hidden.contains("GitHub token") && r.hidden.contains("AWS access key") && r.hidden.contains("password in URL"))
    }

    @Test func hidesEnvStyleAssignmentsButKeepsNormalCode() {
        let text = """
            export DB_PASSWORD="s3cr3t-value"
            STRIPE_SECRET: abc123xyz
            let tokenCount = 42
            PORT=8080
            """
        let r = SecretRedactor.redact(text)
        #expect(r.text.contains(#"export DB_PASSWORD="[hidden]""#))
        #expect(r.text.contains("STRIPE_SECRET: [hidden]"))
        #expect(r.text.contains("let tokenCount = 42"))
        #expect(r.text.contains("PORT=8080"))
        #expect(r.hidden.filter { $0 == "secret setting" }.count == 2)
    }

    @Test func hidesOpaqueTokensQuotedKeysAndCutOffKeys() {
        let opaque = "mF_9.B5f-4.1JqM" + String(repeating: "Zx8", count: 6)
        let gitlab = "glpat-" + String(repeating: "Ab3", count: 7)
        let awsSecret = "wJalr" + "XUtnF/" + String(repeating: "K7MDe", count: 4)
        let text = [
            "Authorization: Bearer \(opaque)",
            #"curl -H "Authorization: Bearer \#(opaque)" http://127.0.0.1:47823/mcp"#,
            #"  "SecretAccessKey": "\#(awsSecret)","#,
            "git remote add origin https://oauth2:\(gitlab)@gitlab.com/x.git",
            "-----BEGIN RSA PRIVATE KEY-----",
            "MIIEowIBAAKCAQEA",
        ].joined(separator: "\n")
        let r = SecretRedactor.redact(text)
        #expect(!r.text.contains(opaque))
        #expect(!r.text.contains(awsSecret))
        #expect(!r.text.contains(gitlab))
        #expect(!r.text.contains("MIIEowIBAAKCAQEA"))  // cut off before its END line
        #expect(r.text.contains("http://127.0.0.1:47823/mcp"))
        #expect(SecretRedactor.redact("Use a Bearer token for this API.").hidden.isEmpty)  // prose stays
    }

    @Test func privateKeysAndSummary() {
        let r = SecretRedactor.redact("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----\nok")
        #expect(r.text == "[hidden private key]\nok")
        #expect(SecretRedactor.summary(r.hidden) == "Hid 1 likely secret (private key).")
        #expect(SecretRedactor.summary([]) == nil)
        #expect(SecretRedactor.redact("nothing secret here").hidden.isEmpty)
    }
}
