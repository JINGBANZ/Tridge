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
        let service = ScanAPIConfig.service
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
        // Rows naming the same item ("Milk" twice on one receipt) coalesce
        // into one review row with summed quantity, so the review count and
        // the merge planner both see one row per item.
        var rows: [ReviewItem] = []
        var indexByKey: [String: Int] = [:]
        for parsed in receipt.items {
            let key = NameKey.normalize(parsed.name)
            if !key.isEmpty, let index = indexByKey[key] {
                rows[index].quantity = min(rows[index].quantity + parsed.quantity,
                                           MergePlanner.maxQuantity)
                continue
            }
            indexByKey[key] = rows.count
            rows.append(ReviewItem(
                itemID: parsed.id,
                name: parsed.name,
                receiptText: parsed.receiptText,
                quantity: parsed.quantity,
                expiryDate: Calendar.current.date(byAdding: .day, value: parsed.shelfLifeDays,
                                                  to: purchase) ?? purchase))
        }
        reviewItems = rows
    }

    /// Saves the reviewed rows, merging each into a matching active item
    /// where one exists (issue #26) and inserting the rest, then schedules
    /// notifications for the genuinely new items and ends the flow.
    func confirm(into context: ModelContext, notificationHour: Int) {
        let storage = defaultStorageLocation()
        let active = (try? context.fetch(FetchDescriptor<FridgeItem>(
            predicate: #Predicate { $0.statusRaw == "active" }))) ?? []
        // The candidate list is updated as rows land so review-time renames
        // that collide (two rows made "Milk") stack instead of clobbering.
        var candidates = active.map(\.mergeCandidate)
        var inserted: [FridgeItem] = []

        for row in reviewItems {
            switch MergePlanner.decide(name: row.name, quantity: row.quantity,
                                       existing: candidates) {
            case .merge(let id, let resultingQuantity):
                guard let target = active.first(where: { $0.id == id }) else { continue }
                // Quantity grows; the existing expiry (and its source) always
                // wins — a scan never overwrites a date already in the fridge.
                target.quantity = resultingQuantity
                if let receiptText = row.receiptText { target.receiptText = receiptText }
                if let index = candidates.firstIndex(where: { $0.id == id }) {
                    candidates[index] = target.mergeCandidate
                }
            case .insert:
                let item = FridgeItem(
                    name: row.name,
                    receiptText: row.receiptText,
                    artKey: row.itemID.rawValue,
                    quantity: row.quantity,
                    storage: storage,
                    purchaseDate: reviewPurchaseDate,
                    expiryDate: row.expiryDate,
                    expirySource: row.userEditedDate ? .userSet : .llmEstimate)
                context.insert(item)
                inserted.append(item)
                candidates.append(item.mergeCandidate)
            }
        }
        Haptics.success()
        Task {
            // Permission is requested on first successful add, not at launch.
            await NotificationService.requestPermissionIfNeeded()
            for item in inserted {
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
