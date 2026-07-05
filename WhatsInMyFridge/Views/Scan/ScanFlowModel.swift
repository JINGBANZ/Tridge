import SwiftUI
import SwiftData

/// Owns the camera → LLM → review pipeline for one receipt scan.
@Observable @MainActor
final class ScanFlowModel {
    enum Phase: Equatable {
        case idle
        case needsKey      // no API key: route to Settings with an explainer
        case camera
        case processing
        case review
        case failed(String)
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

    func startScan() {
        phase = KeychainStore.apiKey == nil ? .needsKey : .camera
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
        guard let apiKey = KeychainStore.apiKey else {
            phase = .needsKey
            return
        }
        phase = .processing
        let service: LLMService = OpenAIService(apiKey: apiKey)
        Task {
            do {
                guard let jpeg = image.receiptJPEGData() else { throw LLMError.unparseable }
                let receipt = try await service.parseReceipt(jpegData: jpeg)
                load(receipt, capturedOn: Date())
                phase = .review
            } catch {
                let message = (error as? LLMError)?.errorDescription
                    ?? LLMError.network(underlying: error).errorDescription
                    ?? "Something went wrong."
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
