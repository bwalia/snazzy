import SnazzyCore
import SwiftUI

/// First launch (and when the terms change): what Snazzy Pro does, and
/// agreeing to the Terms of Use and Privacy Policy before using it.
struct WelcomeView: View {
    var onAccept: () -> Void
    @State private var agreed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            VStack(spacing: 6) {
                Text("Welcome to Snazzy Pro")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 1), Color(red: 0.85, green: 0.27, blue: 0.94), Color(red: 1, green: 0.42, blue: 0.33)],
                                                    startPoint: .leading, endPoint: .trailing))
                Text("A presentation studio you run by conversation.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                row("bubble.left.and.text.bubble.right", "Talk, and it builds", "Plans your talk and builds the slides or a prototype as you watch.")
                row("record.circle", "Present and record", "Slides, screen, camera and mic in one take, with your notes in front of you.")
                row("dot.radiowaves.left.and.right", "Teach and go live", "A live room students join from a QR code, or stream to YouTube.")
                row("lock.shield", "Your Mac, your work", "Everything stays on your Mac. It asks before anything goes to a cloud AI or the internet.")
            }
            .frame(maxWidth: 440, alignment: .leading)

            LegalDocumentsView()
                .frame(height: 210)

            VStack(spacing: 12) {
                Toggle(isOn: $agreed) {
                    HStack(spacing: 4) {
                        Text("I agree to the")
                        Link("Terms of Use", destination: Legal.termsURL)
                        Text("and")
                        Link("Privacy Policy", destination: Legal.privacyURL)
                    }
                }
                .toggleStyle(.checkbox)
                HStack {
                    Button("Quit") { NSApp.terminate(nil) }
                    Button("Continue") { onAccept() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!agreed)
                }
                .controlSize(.large)
            }
            Text("Recording or streaming people? Tell them first: the law may require it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 580)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A short branded splash while the main window appears (under a second; a click skips it).
struct SplashView: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.063, blue: 0.125)
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .scaleEffect(shown ? 1 : 0.86)
                Text("Snazzy Pro")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 1), Color(red: 0.85, green: 0.27, blue: 0.94), Color(red: 1, green: 0.42, blue: 0.33)],
                                                    startPoint: .leading, endPoint: .trailing))
                Text("Just say it.").font(.title3).foregroundStyle(.white.opacity(0.7))
            }
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { shown = true } }
    }
}
