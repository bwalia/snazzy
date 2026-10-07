import Foundation

/// Switches and destinations for the developer features (Settings › Developer).
/// Secrets (S3 keys, GitHub token) are in the Keychain, never here.
public struct DeveloperSettings: Codable, Hashable, Sendable {
    public var trimEnabled = true
    public var captionsEnabled = true
    /// Uploading is off until the user adds a destination and turns it on.
    public var shareEnabled = false
    public var pullRequestDemosEnabled = false
    public var screenReadingEnabled = false
    public var zoomEnabled = false

    public var s3: S3Destination?
    /// "owner/repo" for GitHub release-asset uploads.
    public var githubShareRepo: String?
    /// How long S3 share links work, in hours (max 168 = 7 days, the S3 limit).
    public var shareLinkHours = 72
    /// Diffs longer than this are cut before the assistant sees them.
    public var maxDiffCharacters = 60_000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeveloperSettings()
        trimEnabled = try c.decodeIfPresent(Bool.self, forKey: .trimEnabled) ?? d.trimEnabled
        captionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .captionsEnabled) ?? d.captionsEnabled
        shareEnabled = try c.decodeIfPresent(Bool.self, forKey: .shareEnabled) ?? d.shareEnabled
        pullRequestDemosEnabled = try c.decodeIfPresent(Bool.self, forKey: .pullRequestDemosEnabled) ?? d.pullRequestDemosEnabled
        screenReadingEnabled = try c.decodeIfPresent(Bool.self, forKey: .screenReadingEnabled) ?? d.screenReadingEnabled
        zoomEnabled = try c.decodeIfPresent(Bool.self, forKey: .zoomEnabled) ?? d.zoomEnabled
        s3 = try c.decodeIfPresent(S3Destination.self, forKey: .s3)
        githubShareRepo = try c.decodeIfPresent(String.self, forKey: .githubShareRepo)
        shareLinkHours = try c.decodeIfPresent(Int.self, forKey: .shareLinkHours) ?? d.shareLinkHours
        maxDiffCharacters = try c.decodeIfPresent(Int.self, forKey: .maxDiffCharacters) ?? d.maxDiffCharacters
    }

    public static let storeKey = "SnazzyPro.developer.v1"

    public static func load(_ defaults: UserDefaults = .standard) -> DeveloperSettings {
        defaults.data(forKey: storeKey).flatMap { try? JSONDecoder().decode(DeveloperSettings.self, from: $0) } ?? DeveloperSettings()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storeKey) }
    }
}

/// An S3-compatible bucket (AWS S3, Cloudflare R2, MinIO…).
public struct S3Destination: Codable, Hashable, Sendable {
    /// e.g. https://s3.eu-west-2.amazonaws.com, https://<account>.r2.cloudflarestorage.com, http://localhost:9000
    public var endpoint: String
    public var region: String
    public var bucket: String
    /// Folder inside the bucket, e.g. "snazzy/".
    public var prefix: String
    /// Path-style URLs (endpoint/bucket/key): needed for MinIO and R2; AWS also accepts them.
    public var pathStyle: Bool

    public init(endpoint: String, region: String, bucket: String, prefix: String = "snazzy-pro/", pathStyle: Bool = true) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.pathStyle = pathStyle
    }
}
