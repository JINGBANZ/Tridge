import Foundation

/// A decision only the user can take: their CloudKit data is gone or
/// unreadable, and what happens to the local copy depends on what they say.
///
/// The two causes are kept apart all the way to the wording. A deleted zone is
/// something somebody did; an encrypted-key reset is a key rotation that leaves
/// existing values unreadable. Calling one the other would tell a user something
/// untrue about their own data — and neither message ever names a record, a
/// zone, or anything else opaque that the recovery happens to need.
struct HouseholdRecoveryRequest: Equatable, Identifiable {
    enum Cause: Equatable {
        case zoneDeleted
        case encryptionKeyReset
    }

    /// Which side of the account this happened to. It comes from the store the
    /// failing event named, which is also what decides who can fix it: an owner
    /// can rebuild their own zone from the local cache, a member cannot rebuild
    /// somebody else's.
    enum Role: Equatable {
        case owner
        case member
    }

    let cause: Cause
    let role: Role
    /// The Households hidden while this decision is pending.
    let householdIDs: [UUID]

    var id: String { "\(cause).\(role)" }

    /// Whether the user has to answer before anything local is touched.
    ///
    /// An owner is asked, because their local cache is the only remaining copy
    /// and purging it is irreversible. A member is not: the data was never
    /// theirs to keep, it is already gone, and there is nothing to decide.
    var needsConfirmation: Bool { role == .owner }

    var title: String {
        switch (cause, role) {
        case (.zoneDeleted, .owner): "Your iCloud fridge data was deleted"
        case (.zoneDeleted, .member): "That shared fridge is gone"
        case (.encryptionKeyReset, .owner): "iCloud reset your encryption key"
        case (.encryptionKeyReset, .member): "That shared fridge can't be read"
        }
    }

    var message: String {
        switch (cause, role) {
        case (.zoneDeleted, .owner):
            """
            Tridge's data was removed from your iCloud account, so it can't sync \
            any more. Tridge can keep what's on this iPhone and start fresh in \
            iCloud.
            """
        case (.zoneDeleted, .member):
            """
            The person who started it removed it, so it's no longer on your \
            devices. Ask them for a new invitation if it comes back.
            """
        case (.encryptionKeyReset, .owner):
            """
            iCloud changed the key that protects your data, so what's already \
            stored there can't be read. Tridge can keep what's on this iPhone \
            and store it again under the new key. If you'd shared this fridge, \
            you'll need to invite people again.
            """
        case (.encryptionKeyReset, .member):
            """
            iCloud changed the key that protects this fridge, so it can't be \
            read on your devices. Ask the person who started it for a new \
            invitation.
            """
        }
    }

    /// What the confirming button says. Nil when there is nothing to confirm.
    var confirmationTitle: String? {
        guard needsConfirmation else { return nil }
        return "Keep What's On This iPhone"
    }
}
