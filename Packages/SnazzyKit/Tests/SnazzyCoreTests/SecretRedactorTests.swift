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

    @Test func privateKeysAndSummary() {
        let r = SecretRedactor.redact("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----\nok")
        #expect(r.text == "[hidden private key]\nok")
        #expect(SecretRedactor.summary(r.hidden) == "Hid 1 likely secret (private key).")
        #expect(SecretRedactor.summary([]) == nil)
        #expect(SecretRedactor.redact("nothing secret here").hidden.isEmpty)
    }
}
