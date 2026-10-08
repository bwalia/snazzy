@preconcurrency import AVFoundation
import SwiftUI

/// First run (or "Pair another Mac"): scan the QR code shown on the Mac.
struct PairView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isSheet = false
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 1), Color(red: 0.85, green: 0.27, blue: 0.94), Color(red: 1, green: 0.42, blue: 0.33)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 72, height: 72)
                .overlay(Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white))
            Text("Control Snazzy Pro from here").font(.title.bold()).multilineTextAlignment(.center)
            Text("Start and stop recording, change slides, read your speaker notes and talk to the assistant, from across the room.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "On your Mac, open Snazzy Pro › Devices › iPhone & iPad Remote… › Pair a Device.")
                step(2, "Scan the QR code below (or with the Camera app).")
                step(3, "Keep both on the same Wi-Fi.")
            }
            .frame(maxWidth: 460, alignment: .leading)

            if scanning {
                QRScannerView { code in
                    scanning = false
                    if let url = URL(string: code) {
                        model.pair(with: url)
                        if isSheet { dismiss() }
                    }
                }
                .frame(maxWidth: 420, maxHeight: 420)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                Button("Cancel") { scanning = false }
            } else {
                Button {
                    scanning = true
                } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder").font(.headline).frame(maxWidth: 320).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            ConnectionLine()
            Spacer(minLength: 20)
        }
        .padding(24)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26).background(.tint.opacity(0.3), in: Circle())
            Text(text)
        }
    }
}

/// Connection state, in words.
struct ConnectionLine: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        switch model.connection {
        case .idle: EmptyView()
        case .searching: Label("Looking for your Mac…", systemImage: "wifi").foregroundStyle(.secondary)
        case .connecting(let name): Label("Connecting to \(name)…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .connected(let name): Label("Connected to \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).multilineTextAlignment(.center)
        }
    }
}

/// Camera QR scanner (AVFoundation metadata output).
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else {
                let label = UILabel()
                label.text = "The camera isn't available. Allow it in Settings › Snazzy Pro."
                label.numberOfLines = 0
                label.textColor = .white
                label.frame = view.bounds.insetBy(dx: 20, dy: 20)
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(label)
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            let s = session
            DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let s = session
            DispatchQueue.global().async { s.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
            MainActor.assumeIsolated {
                guard !done, let code, code.hasPrefix("snazzypro://pair") else { return }
                done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode?(code)
            }
        }
    }
}
