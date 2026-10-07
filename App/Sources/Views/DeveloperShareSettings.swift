import SnazzyCore
import SwiftUI

/// Settings › Developer › Share: destinations the user owns.
struct DeveloperShareSection: View {
    @Environment(AppModel.self) private var model
    @State private var endpoint = ""
    @State private var region = ""
    @State private var bucket = ""
    @State private var prefix = "snazzy-pro/"
    @State private var pathStyle = true
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var githubToken = ""
    @State private var githubRepo = ""
    @State private var status: String?

    var body: some View {
        let dev = model.developer!
        let share = dev.share!
        Section {
            Toggle("Share links", isOn: Binding(get: { dev.settings.shareEnabled }, set: { dev.settings.shareEnabled = $0 }))
            Text("Off by default. Uploads go only to places you own, and you approve each one.")
                .font(.caption).foregroundStyle(.secondary)
            if dev.settings.shareEnabled {
                DisclosureGroup("S3-compatible bucket (AWS S3, Cloudflare R2, MinIO)") {
                    TextField("Endpoint", text: $endpoint, prompt: Text("https://s3.eu-west-2.amazonaws.com"))
                    TextField("Region", text: $region, prompt: Text("eu-west-2 (R2: auto)"))
                    TextField("Bucket", text: $bucket)
                    TextField("Folder", text: $prefix)
                    Toggle("Path-style URLs (MinIO, R2)", isOn: $pathStyle)
                    SecureField("Access key ID", text: $accessKey, prompt: Text(share.secret(ShareService.s3AccessAccount) == nil ? "" : "Stored in Keychain"))
                    SecureField("Secret access key", text: $secretKey, prompt: Text(share.secret(ShareService.s3SecretAccount) == nil ? "" : "Stored in Keychain"))
                    Stepper("Links work for \(dev.settings.shareLinkHours) hours", value: Binding(get: { dev.settings.shareLinkHours },
                            set: { dev.settings.shareLinkHours = $0 }), in: 1...168, step: 1)
                    HStack {
                        Button("Save") { saveS3() }
                        Button("Test Connection") { Task { await testS3() } }
                        if let status { Text(status).font(.caption) }
                    }
                }
                DisclosureGroup("GitHub (release assets and Gists)") {
                    SecureField("Token", text: $githubToken, prompt: Text(share.secret(ShareService.githubAccount) == nil
                        ? "Fine-grained token: Contents read/write, Gists" : "Stored in Keychain"))
                    TextField("Repository for videos", text: $githubRepo, prompt: Text("owner/repo"))
                    Text("Release assets in a public repository are public. The same token is used for pull-request demos.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save") { saveGitHub() }
                }
                if !share.records.isEmpty {
                    DisclosureGroup("Shared (\(share.records.filter { !$0.deleted }.count))") {
                        ForEach(share.records) { r in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(r.file).font(.caption).lineLimit(1)
                                    Text("\(r.target.label) · \(r.date.formatted(date: .abbreviated, time: .shortened))\(r.deleted ? " · deleted" : "")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !r.deleted {
                                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.url, forType: .string) }
                                    Button("Delete Remote Copy", role: .destructive) {
                                        Task { do { try await share.deleteRemote(r) } catch { status = error.localizedDescription } }
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        } header: { Text("Share") }
        .onAppear(perform: load)
    }

    private func load() {
        let s = model.developer.settings
        if let d = s.s3 { endpoint = d.endpoint; region = d.region; bucket = d.bucket; prefix = d.prefix; pathStyle = d.pathStyle }
        githubRepo = s.githubShareRepo ?? ""
    }

    private func saveS3() {
        let dev = model.developer!
        dev.settings.s3 = S3Destination(endpoint: endpoint.trimmingCharacters(in: .whitespaces), region: region.trimmingCharacters(in: .whitespaces),
                                        bucket: bucket.trimmingCharacters(in: .whitespaces), prefix: prefix, pathStyle: pathStyle)
        if !accessKey.isEmpty { try? model.secrets.setSecret(accessKey, for: ShareService.s3AccessAccount); accessKey = "" }
        if !secretKey.isEmpty { try? model.secrets.setSecret(secretKey, for: ShareService.s3SecretAccount); secretKey = "" }
        status = "Saved"
    }

    private func testS3() async {
        saveS3()
        status = "Testing…"
        do { try await model.developer.share.testS3(); status = "✓ Upload and delete worked" } catch { status = error.localizedDescription }
    }

    private func saveGitHub() {
        if !githubToken.isEmpty { try? model.secrets.setSecret(githubToken, for: ShareService.githubAccount); githubToken = "" }
        model.developer.settings.githubShareRepo = githubRepo.trimmingCharacters(in: .whitespaces).isEmpty ? nil : githubRepo.trimmingCharacters(in: .whitespaces)
    }
}
