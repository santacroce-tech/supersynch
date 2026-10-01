import SwiftUI
import VisionKit

/// Live camera QR scanner (VisionKit). Calls `onScan` with the first
/// payload that `accept` returns true for.
struct QRScannerView: UIViewControllerRepresentable {
    let accept: (String) -> Bool
    let onScan: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScannerView
        private var done = false

        init(parent: QRScannerView) { self.parent = parent }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case let .barcode(code) in items {
                if let payload = code.payloadStringValue, parent.accept(payload) {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    parent.onScan(payload)
                    return
                }
            }
        }
    }
}
