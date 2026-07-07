import SwiftUI
import SwiftData
import PhotosUI

/// Owns the camera → LLM → review pipeline for one receipt scan.
@Observable @MainActor
final class ScanFlowModel {
    enum Phase: Equatable {
        case idle
        case camera
        case photoPicker   // photo-library import: the camera-free scan path
        case processing
        case review
        case failed(String)
    }

    enum Source {
        case automatic, camera, photoLibrary
    }

    /// One editable row in the review sheet.
    struct ReviewItem: Identifiable {
        let id = UUID()
        var itemID: ItemID
        var name: String
        var receiptText: String?
        var quantity: Int
        var expiryDate: Date
        /// Set when the user touches the date chip; such dates save as
        /// `.userSet` and are never overwritten by later LLM guesses.
        var userEditedDate = false

        /// The LLM couldn't identify this line — flagged amber for fixing.
        var needsFix: Bool { itemID == .unknown }
        var emoji: String { itemID.emoji }
    }

    var phase: Phase = .idle
    /// The purchase date is the day the receipt was photographed — it is not
    /// read off the receipt.
    var reviewPurchaseDate = Date()
    var reviewItems: [ReviewItem] = []

    /// Kept so a failed LLM call can be retried without re-photographing.
    private var pendingImage: UIImage?

    func startScan(from source: Source = .automatic) {
        switch source {
        case .camera:
            phase = .camera
        case .photoLibrary:
            phase = .photoPicker
        case .automatic:
            // No document camera (Simulator, browser-hosted simulators) →
            // fall straight through to the photo-library picker.
            phase = DocumentCameraView.isCameraSupported ? .camera : .photoPicker
        }
    }

    #if DEBUG
    /// Runs the bundled synthetic receipt through the real pipeline — lets the
    /// whole scan flow be exercised where neither camera nor photo library has
    /// a receipt to offer (fresh simulators, browser sessions).
    func scanSampleReceipt() {
        guard let url = Bundle.main.url(forResource: "SampleReceipt", withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path) else {
            AppLog.scan.error("SampleReceipt.jpg missing from bundle")
            return
        }
        handleCapture(image)
    }
    #endif

    /// Loads a photo-library selection. Failures are logged and surfaced —
    /// unlike a camera cancel, the user picked something and expects a result.
    func handlePickedPhoto(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    AppLog.scan.error("Photo import produced no usable image data")
                    phase = .failed("That photo couldn't be loaded. Try a different one.")
                    return
                }
                handleCapture(image)
            } catch {
                AppLog.scan.error("Photo import failed: \(error.localizedDescription)")
                phase = .failed("That photo couldn't be loaded. Try a different one.")
            }
        }
    }

    func handleCapture(_ image: UIImage?) {
        guard let image else {
            phase = .idle
            return
        }
        pendingImage = image
        process(image)
    }

    func retry() {
        if let pendingImage {
            process(pendingImage)
        } else {
            startScan()
        }
    }

    func reset() {
        phase = .idle
        pendingImage = nil
        reviewItems = []
    }

    private func process(_ image: UIImage) {
        guard let service = ScanAPIConfig.service else {
            // Only happens in a build with no bearer token (Secrets.xcconfig
            // missing) — surface it instead of silently 401-ing on the worker.
            AppLog.scan.error("No scan API token in this build — cannot scan")
            phase = .failed("Scanning isn't set up in this build.")
            return
        }
        phase = .processing
        Task {
            do {
                guard let jpeg = image.receiptJPEGData() else { throw LLMError.unparseable }
                AppLog.scan.info("Scanning \(Int(image.size.width))×\(Int(image.size.height)) image, \(jpeg.count / 1024) KB JPEG")
                let receipt = try await service.parseReceipt(jpegData: jpeg)
                AppLog.scan.info("Review ready: \(receipt.items.count) items")
                load(receipt, capturedOn: Date())
                phase = .review
            } catch {
                let message = (error as? LLMError)?.errorDescription
                    ?? LLMError.network(underlying: error).errorDescription
                    ?? "Something went wrong."
                AppLog.scan.error("Scan failed: \(message)")
                phase = .failed(message)
            }
        }
    }

    func load(_ receipt: ParsedReceipt, capturedOn purchase: Date) {
        reviewPurchaseDate = purchase
        reviewItems = receipt.items.map { parsed in
            ReviewItem(
                itemID: parsed.id,
                name: parsed.name,
                receiptText: parsed.receiptText,
                quantity: parsed.quantity,
                expiryDate: Calendar.current.date(byAdding: .day, value: parsed.shelfLifeDays,
                                                  to: purchase) ?? purchase)
        }
    }

    /// Saves all reviewed rows, schedules their notifications, and ends the flow.
    func confirm(into context: ModelContext, notificationHour: Int) {
        let storage = defaultStorageLocation()
        let items = reviewItems.map { row in
            FridgeItem(
                name: row.name,
                receiptText: row.receiptText,
                artKey: row.itemID.rawValue,
                quantity: row.quantity,
                storage: storage,
                purchaseDate: reviewPurchaseDate,
                expiryDate: row.expiryDate,
                expirySource: row.userEditedDate ? .userSet : .llmEstimate)
        }
        for item in items {
            context.insert(item)
        }
        Haptics.success()
        Task {
            // Permission is requested on first successful add, not at launch.
            await NotificationService.requestPermissionIfNeeded()
            for item in items {
                NotificationService.schedule(for: item, hour: notificationHour)
            }
        }
        reset()
    }

    private func defaultStorageLocation() -> StorageLocation {
        let raw = UserDefaults.standard.string(forKey: "defaultStorage") ?? ""
        return StorageLocation(rawValue: raw) ?? .fridge
    }
}
