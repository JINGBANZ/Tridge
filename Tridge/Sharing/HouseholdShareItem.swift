import CloudKit
import CoreTransferable
import SwiftUI

/// What `ShareLink` exports for a Household: a share that is already saved
/// server-side, plus the invitation restrictions Tridge insists on.
///
/// It uses `.existing(_:container:allowedSharingOptions:)` rather than
/// `.prepareShare`, because the create/refresh flow has already saved the share
/// and persisted its current title — `.prepareShare` is the representation for
/// creating and saving a *new* share, which would bypass that guarantee.
struct HouseholdShareItem: Transferable {
    let share: CKShare
    /// The container the share belongs to, by identifier.
    ///
    /// Resolved to a `CKContainer` only when the sheet actually exports it:
    /// constructing one requires the iCloud entitlement, and nothing else here
    /// needs a container at all.
    let containerIdentifier: String
    /// The Household name, used for the share sheet's preview.
    let title: String

    /// Specified recipients, read/write, no public access.
    ///
    /// `.specifiedRecipientsOnly` is what removes public links from the sheet,
    /// and `.readWrite` is the only participant permission Tridge offers — the
    /// product has no read-only role. `allowsAccessRequests` and
    /// `allowsParticipantsToInviteOthers` are deliberately left at their
    /// documented `false` defaults rather than reassigned: setting a value
    /// equal to the default would only add an availability branch, and
    /// `publicPermission` stays `.none` because nothing here grants it.
    ///
    /// Both option properties exist from iOS 16, so they cover the iOS 18
    /// deployment target even though the SDK is newer.
    static var allowedSharingOptions: CKAllowedSharingOptions {
        CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                allowedParticipantAccessOptions: .specifiedRecipientsOnly)
    }

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            .existing(item.share,
                      container: CKContainer(identifier: item.containerIdentifier),
                      allowedSharingOptions: Self.allowedSharingOptions)
        }
    }
}
