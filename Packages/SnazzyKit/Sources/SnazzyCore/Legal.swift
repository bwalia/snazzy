import Foundation

/// The Terms of Use and Privacy Policy people agree to on first launch.
/// Bump `termsVersion` when the terms change in a way that matters: the
/// welcome screen asks again.
public enum Legal {
    public static let termsVersion = 1
    public static let termsURL = URL(string: "https://bwalia.github.io/snazzy/terms.html")!
    public static let privacyURL = URL(string: "https://bwalia.github.io/snazzy/privacy.html")!
    static let acceptedKey = "SnazzyPro.acceptedTermsVersion"
    static let acceptedDateKey = "SnazzyPro.acceptedTermsDate"

    public static func hasAccepted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: acceptedKey) >= termsVersion
    }

    public static func accept(_ defaults: UserDefaults = .standard, date: Date = Date()) {
        defaults.set(termsVersion, forKey: acceptedKey)
        defaults.set(date, forKey: acceptedDateKey)
    }

    public static func acceptedDate(_ defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: acceptedDateKey) as? Date
    }
}
