import CoreData

/// Destroys the archived pre-sharing SQLite store, and nothing else.
///
/// This is the only path in the release that deletes those files, and it runs
/// only when the user asks. It is written to fail closed: the targets are the
/// three exact paths the shipping build created, each is checked to be a
/// regular local file outside the sharing stack's own directory, and a
/// mismatch stops the whole operation rather than widening it. It never
/// enumerates a directory, never follows a link, and never touches a current
/// Household store or any CloudKit data.
struct LegacyArchiveEraser {
    /// Why an erasure did not complete. Content-free: a stage and, at most, an
    /// error code — never a path, which would carry the account directory into
    /// a log.
    enum Failure: Error, Equatable {
        /// A target exists but is not a plain local file this may destroy —
        /// a symbolic link, a directory, or something inside the sharing
        /// stack's own storage.
        case invalidTarget
        /// Application Support could not be resolved, so there is no archive to
        /// name.
        case unresolvedLocation
        case destroyFailed(diagnosticID: String)
        case removeFailed(diagnosticID: String)
        /// A file survived both the store destruction and the removal.
        case remnantsRemain
    }

    /// The directory the sharing stack owns. A target inside it is never the
    /// legacy archive, whatever its name.
    static let protectedDirectoryComponent = "HouseholdSharing"

    private let storeURL: URL?
    private let fileManager: FileManager

    init(storeURL: URL? = LegacyInventoryArchive.defaultStoreURL,
         fileManager: FileManager = .default) {
        self.storeURL = storeURL
        self.fileManager = fileManager
    }

    /// The exact base plus its two sidecars, in destruction order.
    var targets: [URL] {
        guard let storeURL else { return [] }
        return [storeURL] + LegacyInventoryArchive.sidecarSuffixes.map {
            URL(fileURLWithPath: storeURL.path + $0)
        }
    }

    /// Whether anything is still there to erase. The files themselves are the
    /// record, which is why this path needs no marker of its own.
    var hasRemnants: Bool {
        targets.contains { fileManager.fileExists(atPath: $0.path) }
    }

    /// Destroys the store and removes the validated remnants.
    ///
    /// Idempotent: a target that is already gone is success, so a Retry after a
    /// partial failure finishes the job rather than starting an argument.
    func erase() throws {
        guard storeURL != nil else { throw Failure.unresolvedLocation }
        let targets = self.targets
        try targets.forEach(validate)

        // Only when the base file is there: destroying a store that is not
        // there is not a no-op in Core Data, and Retry has to be able to run
        // after a crash that left only the sidecars.
        if let base = targets.first, fileManager.fileExists(atPath: base.path) {
            do {
                try NSPersistentStoreCoordinator.destroyPersistentStore(
                    at: base, type: .sqlite, options: nil)
            } catch {
                let details = error as NSError
                throw Failure.destroyFailed(
                    diagnosticID: "legacyErase.destroy.\(details.domain).\(details.code)")
            }
        }

        for target in targets where fileManager.fileExists(atPath: target.path) {
            do {
                try fileManager.removeItem(at: target)
            } catch let error as NSError where error.code == NSFileNoSuchFileError {
                continue
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                let details = error as NSError
                throw Failure.removeFailed(
                    diagnosticID: "legacyErase.remove.\(details.domain).\(details.code)")
            }
        }

        guard !hasRemnants else { throw Failure.remnantsRemain }
    }

    /// A target may be erased only if it is absent, or a regular local file
    /// outside the sharing stack's storage.
    ///
    /// `attributesOfItem` reports the item itself rather than what it points
    /// at, so a symbolic link is recognized as a link and refused instead of
    /// being followed somewhere this has no business deleting.
    private func validate(_ url: URL) throws {
        guard !url.pathComponents.contains(Self.protectedDirectoryComponent) else {
            throw Failure.invalidTarget
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { throw Failure.invalidTarget }
    }
}

extension LegacyArchiveEraser.Failure {
    /// Content-free and safe to quote in a support report.
    var diagnosticID: String {
        switch self {
        case .invalidTarget: "legacyErase.target"
        case .unresolvedLocation: "legacyErase.location"
        case .remnantsRemain: "legacyErase.remnants"
        case .destroyFailed(let id), .removeFailed(let id): id
        }
    }
}
