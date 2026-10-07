import Foundation
import Testing
@testable import SnazzyCore

@Suite struct JSONValueTests {
    @Test func roundTripsAndKeepsIntegersIntegral() throws {
        let value: JSONValue = ["a": 1, "b": [true, .null, "x"], "c": 1.5]
        let text = value.compactString
        #expect(text == #"{"a":1,"b":[true,null,"x"],"c":1.5}"#)
        #expect(try JSONValue.parse(text) == value)
    }

    @Test func schemaTypeNames() {
        #expect(JSONValue.number(3).schemaTypeName == "integer")
        #expect(JSONValue.number(3.2).schemaTypeName == "number")
        #expect(JSONValue.object([:]).schemaTypeName == "object")
    }
}

@Suite struct SettingsTests {
    @Test func roundTrip() throws {
        var settings = AppSettings.default
        settings.setSelection(ModelSelection(provider: .ollama, model: "gpt-oss:120b"), for: .quickCommands)
        settings.activeTask = .writing
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.selection(for: .quickCommands).provider == .ollama)
    }

    @Test func missingFieldsFallBackToDefaults() throws {
        let json = #"{"activeTask":"writing","ollamaBaseURL":"http://example.local:11434"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.activeTask == .writing)
        #expect(decoded.ollamaBaseURL == "http://example.local:11434")
        #expect(decoded.planning == AppSettings.default.planning)
    }

    @Test func storePersistsWithoutSecrets() throws {
        let suite = "SnazzyProTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SettingsStore(suiteName: suite)
        #expect(store.load() == .default)
        var settings = AppSettings.default
        settings.anthropicEffort = "high"
        store.save(settings)
        #expect(store.load().anthropicEffort == "high")
        let raw = try #require(UserDefaults(suiteName: suite)?.data(forKey: SettingsStore.key))
        #expect(!String(decoding: raw, as: UTF8.self).lowercased().contains("key\""))
    }

    @Test func localAndCloudProviders() {
        #expect(ProviderKind.ollama.isLocal)
        #expect(!ProviderKind.anthropic.isLocal)
        #expect(ProviderKind.anthropic.keychainAccount == "anthropic")
        #expect(ProviderKind.ollama.keychainAccount == nil)
    }
}

@Suite struct SecretStoreTests {
    @Test func inMemory() throws {
        let store = InMemorySecretStore()
        #expect(try store.secret(for: "a") == nil)
        try store.setSecret("s1", for: "a")
        try store.setSecret("s2", for: "a")
        #expect(try store.secret(for: "a") == "s2")
        try store.deleteSecret(for: "a")
        #expect(try store.secret(for: "a") == nil)
    }

    /// Touches the real login Keychain; opt in with SNAZZY_KEYCHAIN_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SNAZZY_KEYCHAIN_TESTS"] == "1"))
    func keychainRoundTrip() throws {
        let store = KeychainStore(service: "com.snazzy.pro.tests.\(UUID().uuidString)")
        defer { try? store.deleteSecret(for: "test") }
        #expect(try store.secret(for: "test") == nil)
        try store.setSecret("value-1", for: "test")
        try store.setSecret("value-2", for: "test")
        #expect(try store.secret(for: "test") == "value-2")
        try store.deleteSecret(for: "test")
        #expect(try store.secret(for: "test") == nil)
    }
}
