import CoreData

/// Builds one Household's export document and writes it to a temporary file.
///
/// It reads through the same validating mappers the projector uses, so a corrupt
/// record is omitted with a content-free finding rather than exported as
/// nonsense — and it reads *everything*, not just what is current: superseded,
/// zero, and deleted history is exactly what makes the export honest.
struct InventoryExporter {
    struct ExportError: Error, Equatable {
        let diagnosticID: String
    }

    private let persistence: PersistenceController

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    /// Writes the document to a temporary URL and returns it, ready for the
    /// system share sheet.
    func exportDocument(for householdID: UUID, today: InventoryDay,
                        now: Date = Date()) async throws -> URL {
        let document = try await document(for: householdID, today: today, now: now)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(document.suggestedFileName, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try document.encoded().write(to: url, options: .atomic)
        } catch {
            let details = error as NSError
            throw ExportError(diagnosticID: "export.write.\(details.domain).\(details.code)")
        }
        return url
    }

    func document(for householdID: UUID, today: InventoryDay,
                  now: Date = Date()) async throws -> InventoryExportDocument {
        let context = persistence.newReaderContext()
        let persistence = self.persistence
        return try await context.perform {
            let household = try persistence.resolveHousehold(householdID, in: context).household
            let projection = HouseholdProjector.project(household, today: today)

            var operations: [InventoryExportDocument.StockOperation] = []
            for record in household.items {
                guard let itemID = record.id else { continue }
                for change in record.stockChanges {
                    guard let event = try? change.event() else { continue }
                    operations.append(InventoryExportDocument.StockOperation(event,
                                                                            itemID: itemID))
                }
            }

            let claims = household.itemMerges
                .compactMap { try? $0.claim() }
                .map(InventoryExportDocument.MergeClaim.init)
            let clears = household.clearEvents
                .compactMap { try? $0.event() }
                .map(InventoryExportDocument.ClearEvent.init)

            return InventoryExportDocument(
                exportedAt: now,
                householdName: household.name ?? "",
                items: projection.items.map(InventoryExportDocument.LogicalItem.init),
                physicalItems: projection.physicalItems
                    .map(InventoryExportDocument.PhysicalItem.init),
                // Sorted so two exports of the same fridge diff cleanly.
                stockOperations: operations.sorted { UUIDOrder.isBefore($0.id, $1.id) },
                itemMerges: claims.sorted { UUIDOrder.isBefore($0.id, $1.id) },
                clearEvents: clears.sorted { $0.revision < $1.revision })
        }
    }
}
