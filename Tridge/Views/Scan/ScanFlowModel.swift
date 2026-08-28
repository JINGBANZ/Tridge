import SwiftUI
import PhotosUI

/// Owns the camera → LLM → review pipeline for one receipt scan.
///
/// The draft it holds is the only place raw receipt-line text ever lives: it is
/// shown in Review so the user can check a name against the line it came from,
/// and it is dropped at confirmation. Nothing derived from a receipt image is
/// persisted or synchronized.
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

    /// One editable line in the review sheet.
    struct ReviewItem: Identifiable {
        /// Also the preallocated purchase-root id, so a retry after a failed
        /// confirm writes the same row rather than a second copy.
        let id: UUID
        let stockChangeID: UUID
        var itemID: ItemID
        var name: String
        var receiptText: String?
        var quantity: Int64
        var purchaseDay: InventoryDay
        var expiryDay: InventoryDay
        /// The LLM's guess (fridge, freezer, or pantry), editable via the
        /// row's chip.
        var storage: StorageLocation
        /// What the user changed on purpose. A model guess is never in here, so
        /// it cannot overwrite metadata an existing same-name item already
        /// established (ADR 0011).
        var explicitFields: Set<ExplicitMetadataField> = []

        /// The LLM couldn't identify this line — flagged amber for fixing.
        var needsFix: Bool { itemID == .unknown }
        var emoji: String { itemID.emoji }
        var foodCategory: FoodCategory { itemID.foodCategory }
        var userEditedDate: Bool { explicitFields.contains(.expiryDay) }
    }

    var phase: Phase = .idle
    /// The purchase day is the day the receipt was photographed — it is not
    /// read off the receipt.
    var reviewPurchaseDay = InventoryDay.today()
    var reviewItems: [ReviewItem] = []
    /// True while the confirmation is saving, so Confirm cannot be tapped twice.
    private(set) var isSaving = false

    /// Kept so a failed LLM call can be retried without re-photographing.
    private var pendingImage: UIImage?
    /// Allocated on the first confirm and reused by a retry: a replayed command
    /// has to produce byte-identical events or the repository reads it as a
    /// conflicting payload.
    private var confirmInstant: Date?

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
        confirmInstant = nil
        isSaving = false
    }

    private func process(_ image: UIImage) {
        let service = ScanAPIConfig.service
        phase = .processing
        Task {
            do {
                // The downscale + JPEG encode costs hundreds of ms for a camera
                // capture; a plain `Task` inherits this model's main-actor
                // isolation, so detach or the progress UI freezes.
                guard let jpeg = await Task.detached(priority: .userInitiated,
                                                     operation: { image.receiptJPEGData() }).value
                else { throw LLMError.unparseable }
                AppLog.scan.info("Scanning \(Int(image.size.width))×\(Int(image.size.height)) image, \(jpeg.count / 1024) KB JPEG")
                let receipt = try await service.parseReceipt(jpegData: jpeg)
                AppLog.scan.info("Review ready: \(receipt.items.count) items")
                load(receipt, purchasedOn: InventoryDay.today())
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

    func load(_ receipt: ParsedReceipt, purchasedOn purchaseDay: InventoryDay) {
        reviewPurchaseDay = purchaseDay
        confirmInstant = nil
        // Rows naming the same item ("Milk" twice on one receipt) coalesce
        // into one review row with summed quantity, so the review count and
        // the purchase planner both see one row per item.
        var rows: [ReviewItem] = []
        var indexByKey: [String: Int] = [:]
        for parsed in receipt.items {
            let key = NameKey.normalize(parsed.name)
            if !key.isEmpty, let index = indexByKey[key] {
                let (sum, overflowed) = rows[index].quantity
                    .addingReportingOverflow(Int64(parsed.quantity))
                if !overflowed { rows[index].quantity = sum }
                continue
            }
            indexByKey[key] = rows.count
            // Built through the command's own initializer so the shelf-life
            // clamp lives in exactly one place.
            let seed = PurchaseDraft(reviewing: parsed, itemID: UUID(), stockChangeID: UUID(),
                                     purchaseDay: purchaseDay)
            rows.append(ReviewItem(id: seed.itemID, stockChangeID: seed.stockChangeID,
                                   itemID: parsed.id, name: seed.name,
                                   receiptText: parsed.receiptText, quantity: seed.quantity,
                                   purchaseDay: purchaseDay, expiryDay: seed.expiryDay,
                                   storage: seed.storage))
        }
        reviewItems = rows
    }

    /// Confirms the whole receipt in one atomic save.
    ///
    /// Every row becomes a fresh frontier-stamped purchase root; rows whose name
    /// matches an item already in the fridge project as one logical row
    /// immediately, and the reconciler makes that link permanent. Raw receipt
    /// text stays here and is discarded with the draft.
    func confirm(into session: HouseholdSession) {
        guard !reviewItems.isEmpty, !isSaving else { return }
        let occurredAt = confirmInstant ?? Date()
        confirmInstant = occurredAt
        let drafts = reviewItems.map { row in
            PurchaseDraft(itemID: row.id, stockChangeID: row.stockChangeID, name: row.name,
                          quantity: row.quantity, artKey: row.itemID.rawValue,
                          storage: row.storage, purchaseDay: row.purchaseDay,
                          expiryDay: row.expiryDay,
                          expirySource: row.userEditedDate ? .userSet : .llmEstimate,
                          explicitMetadataFields: row.explicitFields,
                          occurredAt: occurredAt)
        }

        isSaving = true
        Task {
            let saved = await session.addReviewedRows(drafts)
            isSaving = false
            guard saved else { return }
            Haptics.success()
            reset()
        }
    }
}
