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
        var name: String
        var receiptText: String?
        var emoji: String
        var category: FoodCategory
        var quantity: Int
        var storage: StorageLocation
        var expiryDate: Date
        var lowConfidence: Bool
        /// Set when the user touches the date chip; such dates save as
        /// `.userSet` and are never overwritten by later LLM guesses.
        var userEditedDate = false
    }

    var phase: Phase = .idle
    var reviewStore: String?
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
        reviewStore = nil
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
                load(receipt, defaultStorage: defaultStorageLocation())
                phase = .review
            } catch {
                let message = (error as? LLMError)?.errorDescription
                    ?? LLMError.network(underlying: error).errorDescription
                    ?? "Something went wrong."
                phase = .failed(message)
            }
        }
    }

    private func defaultStorageLocation() -> StorageLocation {
        let raw = UserDefaults.standard.string(forKey: "defaultStorage") ?? ""
        return StorageLocation(rawValue: raw) ?? .fridge
    }

    func load(_ receipt: ParsedReceipt, defaultStorage: StorageLocation) {
        let purchase = receipt.purchaseDateValue() ?? Date()
        reviewStore = receipt.store
        reviewPurchaseDate = purchase
        reviewItems = receipt.items.map { parsed in
            ReviewItem(
                name: parsed.name,
                receiptText: parsed.receiptText,
                emoji: Artwork.resolve(key: parsed.emoji, category: parsed.category),
                category: parsed.category,
                quantity: parsed.quantity,
                storage: parsed.storage ?? defaultStorage,
                expiryDate: Calendar.current.date(byAdding: .day, value: parsed.shelfLifeDays,
                                                  to: purchase) ?? purchase,
                lowConfidence: parsed.confidence == .low)
        }
    }

    /// Saves all reviewed rows, schedules their notifications, and ends the flow.
    func confirm(into context: ModelContext, notificationHour: Int) {
        let items = reviewItems.map { row in
            FridgeItem(
                name: row.name,
                receiptText: row.receiptText,
                artKey: row.emoji,
                category: row.category,
                quantity: row.quantity,
                storage: row.storage,
                purchaseDate: reviewPurchaseDate,
                expiryDate: row.expiryDate,
                expirySource: row.userEditedDate ? .userSet : .llmEstimate,
                store: reviewStore)
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
}
