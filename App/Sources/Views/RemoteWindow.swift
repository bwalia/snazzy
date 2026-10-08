import Remote
import SwiftUI

/// Pair the Snazzy Pro iPhone/iPad app and manage paired devices.
struct RemoteWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let remote = model.remote!
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("iPhone & iPad remote").font(.title2.weight(.semibold))
                Text("Use the Snazzy Pro app on your iPhone or iPad to start and stop recording, change slides, read your speaker notes as a teleprompter and talk to the assistant. It connects over your Wi-Fi with encryption; only devices you pair here can connect.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let qr = remote.pairingQR {
                    HStack(alignment: .top, spacing: 20) {
                        Image(nsImage: qr).interpolation(.none).resizable()
                            .frame(width: 220, height: 220).padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .background(HiddenFromScreenSharing())
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scan with your iPhone or iPad").font(.headline)
                            Text("Open the Camera app (or Snazzy Pro on the device › Pair) and point it at the code. Both need to be on the same Wi-Fi.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let expires = remote.pairingExpires {
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    let left = max(0, Int(expires.timeIntervalSince(ctx.date)))
                                    Text("Code works once, for \(left / 60):\(String(format: "%02d", left % 60)) more.")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            HStack {
                                Button("Cancel") { remote.closePairing() }
                                #if DEBUG
                                // Simulators can't scan: launch the iPhone app with -debugPairURL <link>.
                                if let url = remote.pairingURL {
                                    Button("Copy Pairing Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    }
                                }
                                #endif
                            }
                        }
                    }
                } else {
                    Button {
                        Task { await remote.openPairing() }
                    } label: { Label("Pair a Device", systemImage: "qrcode") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }

                if let error = remote.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }

                Divider()
                Text("Paired devices").font(.headline)
                if remote.devices.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(remote.devices) { device in
                        HStack {
                            Image(systemName: device.name.lowercased().contains("ipad") ? "ipad" : "iphone")
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(remote.connected.contains(device.name) ? "Connected" : "Paired \(device.paired.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(remote.connected.contains(device.name) ? .green : .secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { remote.remove(device) }
                                .help("This device can no longer connect until it's paired again")
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// Keeps the window showing the pairing code out of other apps' screen sharing
/// (Zoom, Meet), so viewers can't scan it. Snazzy Pro's own capture already
/// leaves its windows out.
private struct HiddenFromScreenSharing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.sharingType = .none }
    }
}
