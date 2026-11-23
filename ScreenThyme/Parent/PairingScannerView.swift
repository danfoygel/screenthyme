import SwiftUI
import ThymeCore
import VisionKit

/// The parent's side of matching by camera (PLAN.md §15.6, `CameraPairingView` on the kid's phone): reads the codes the
/// kid's phone shows and, each time it has read all of a report's, sends every complete report's codes over the nearby
/// link. That moves the kid's phone on; the kid's phone pairs at the end and sends back what it found.
struct PairingScannerView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    /// Every one of our codes read, as its text.
    @State private var read: Set<String> = []
    /// The texts last sent, so a report is sent once it's complete, not at every frame.
    @State private var sent: Set<String> = []

    var body: some View {
        let peer = model.pairingPeers[kid.id]
        VStack(spacing: 12) {
            if !DataScannerViewController.isSupported {
                ContentUnavailableView("No camera", systemImage: "camera",
                                       description: Text("This phone's camera can't read codes."))
            } else if DataScannerViewController.isAvailable {
                QRScanner { text in
                    guard TokenPairing.decode(text) != nil else { return }
                    read.insert(text)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView("No camera", systemImage: "camera",
                                       description: Text("Allow ScreenThyme to use the camera in Settings."))
            }
            VStack(spacing: 4) {
                Text(status(peer)).multilineTextAlignment(.center)
                if let showing = peer?.showing {
                    Text(parts(of: showing)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minHeight: 60)
        }
        .padding()
        .navigationTitle("Match \(kid.displayName)'s apps")
        .bugButton()
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: sent.count)
        .onAppear {
            model.pairingPeers[kid.id]?.result = nil
            model.startCameraPairing(on: kid.id)
        }
        // A kid's phone that connects while the camera is open opens its side too.
        .onChange(of: model.nearby.isConnected(kid: kid.id)) { _, connected in
            if connected { model.startCameraPairing(on: kid.id) }
        }
        .onChange(of: read) { sendComplete() }
        // The kid's phone asks again for a report already read (it reopened, or a message was lost): send it again.
        .onChange(of: peer?.showing) { sendComplete(again: true) }
    }

    private func status(_ peer: PairingPeer?) -> String {
        guard model.nearby.isConnected(kid: kid.id) else {
            return "Looking for \(kid.displayName)'s phone. Open ScreenThyme on it, keep both phones' Wi-Fi or Bluetooth on."
        }
        if let result = peer?.result { return result }
        guard let peer, peer.total > 0 else {
            return "Opening matching on \(kid.displayName)'s phone…"
        }
        guard peer.showing != nil else { return "Matching on \(kid.displayName)'s phone…" }
        return "Hold the camera over \(kid.displayName)'s screen: report \(peer.done + 1) of \(peer.total)."
    }

    /// How many of the shown report's codes have been read.
    private func parts(of view: String) -> String {
        let codes = read.compactMap(TokenPairing.decode).filter { $0.view.name == view }
        guard let parts = codes.map(\.parts).max() else { return "No code read yet" }
        return "\(Set(codes.map(\.part)).count) of \(parts) codes read"
    }

    private func sendComplete(again: Bool = false) {
        let codes = read.compactMap { text in TokenPairing.decode(text).map { (text, $0) } }
        let complete = TokenPairing.complete(codes.map(\.1))
        let texts = Set(codes.filter { complete[$0.1.fingerprint]?.contains($0.1.view) == true }.map(\.0))
        guard !texts.isEmpty, again || texts != sent else { return }
        sent = texts
        model.sendPairingCodes(texts.sorted(), to: kid.id)
    }
}

/// VisionKit's live scanner, reporting every QR code's text as it comes into view or changes.
private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .accurate, recognizesMultipleItems: true,
                                                isHighFrameRateTrackingEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.found = found
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var found: (String) -> Void

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(addedItems)
        }

        // The kid's report cycles its codes in one place: a new code can come as an update of the last.
        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            report(updatedItems)
        }

        private func report(_ items: [RecognizedItem]) {
            for case let .barcode(barcode) in items {
                if let text = barcode.payloadStringValue { found(text) }
            }
        }
    }
}
