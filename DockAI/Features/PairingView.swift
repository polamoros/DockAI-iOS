import SwiftUI
import VisionKit

/// First launch: scan the QR from Settings → Your devices.
struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State private var scanning = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "qrcode.viewfinder").font(.system(size: 64))
            Text("Pair with DockAI").font(.title2.bold())
            Text("On the web, open Settings → Your devices → Add a device, and scan the code shown there. On this iPhone, tap Open in the DockAI app there, or copy the link and paste it here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            if let error { Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center) }
            Button { scanning = true } label: { Label("Scan code", systemImage: "camera") }
                .buttonStyle(.borderedProminent).disabled(busy || !DataScannerViewController.isSupported)
            // The web page and the app on one iPhone: nothing to scan with.
            // PasteButton reads the clipboard without iOS's paste prompt.
            PasteButton(payloadType: String.self) { strings in
                if let text = strings.first { Task { @MainActor in pair(text) } }
            }
            .disabled(busy)
            if busy { ProgressView() }
            Spacer()
        }
        .padding()
        .sheet(isPresented: $scanning) {
            QRScanner { text in
                scanning = false
                pair(text)
            }.ignoresSafeArea()
        }
    }

    /// A scanned or pasted pairing link. Both are the person's own action on
    /// this screen, so no further confirmation is asked here.
    private func pair(_ text: String) {
        guard let p = Pairing.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "That is not a DockAI pairing link."; return
        }
        busy = true
        error = nil
        Task {
            do {
                let c = try await Pairing.pair(server: p.server, code: p.code, deviceName: UIDevice.current.name)
                model.signedIn(c)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// VisionKit's scanner, for QR codes only.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var done = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items { if case .barcode(let b) = item, let s = b.payloadStringValue { done = true; found(s); return } }
        }
    }
}
