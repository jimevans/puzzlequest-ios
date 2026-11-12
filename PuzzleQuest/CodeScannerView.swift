import SwiftUI
import VisionKit

/// The camera, reading QR codes: each code it sees, as text, goes to
/// `onCode`, many times a second while it's in view. The QR code on a
/// puzzle's card holds just its activation code, so it's read on the phone
/// and sent as if typed; no picture leaves the phone.
struct CodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    /// The camera couldn't be used, as when the player said no to it.
    let onUnavailable: () -> Void

    /// Whether this device can scan: it has a camera VisionKit can read
    /// codes with (a simulator doesn't), and the player hasn't refused it.
    @MainActor
    static var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        guard !scanner.isScanning else { return }
        do {
            // Asks for the camera the first time.
            try scanner.startScanning()
        } catch {
            onUnavailable()
        }
    }

    static func dismantleUIViewController(
        _ scanner: DataScannerViewController, coordinator: Coordinator
    ) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: CodeScannerView

        init(parent: CodeScannerView) {
            self.parent = parent
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            report(addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            report(updatedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            parent.onUnavailable()
        }

        private func report(_ items: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                if let code = barcode.payloadStringValue?.trimmingCharacters(
                    in: .whitespacesAndNewlines), !code.isEmpty
                {
                    parent.onCode(code)
                }
            }
        }
    }
}
