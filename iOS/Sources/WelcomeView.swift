import SnazzyCore
import SwiftUI

/// First launch (and when the terms change): what the app does, and agreeing
/// to the Terms of Use and Privacy Policy.
struct WelcomeView: View {
    var onAccept: () -> Void
    @State private var agreed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 1), Color(red: 0.85, green: 0.27, blue: 0.94), Color(red: 1, green: 0.42, blue: 0.33)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 84, height: 84)
                    .overlay(Image(systemName: "sparkles").font(.system(size: 36, weight: .semibold)).foregroundStyle(.white))
                    .padding(.top, 30)
                Text("Welcome to Snazzy Pro").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text("The remote and teleprompter for Snazzy Pro on your Mac.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 16) {
                    row("record.circle", "Record from anywhere", "Start, pause and stop the recording on your Mac.")
                    row("rectangle.on.rectangle", "Slides and notes", "Change slides and read your speaker notes, large.")
                    row("bubble.left.and.text.bubble.right", "Ask the assistant", "Type or dictate, and the assistant on your Mac does it.")
                    row("lock.shield", "Private by design", "It talks only to your own Mac, encrypted, over your Wi-Fi.")
                }
                .frame(maxWidth: 480, alignment: .leading)
                Toggle(isOn: $agreed) {
                    Text("I agree to the [Terms of Use](\(Legal.termsURL.absoluteString)) and [Privacy Policy](\(Legal.privacyURL.absoluteString))")
                }
                .frame(maxWidth: 480)
                .accessibilityIdentifier("agreeToggle")
                Button {
                    onAccept()
                } label: {
                    Text("Continue").font(.headline).frame(maxWidth: 320).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!agreed)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}
