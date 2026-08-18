import Foundation

public enum ReminderKind: String, Hashable, CaseIterable, Sendable {
    /// The two-day warning.
    case pre
    /// The expiry day itself.
    case day
}

/// A Tridge expiry reminder's identity. Reminders cover the Active Household
/// only, so switching account or household has to retire exactly the previous
/// scope's requests — the identifier carries every part needed to decide that.
///
/// The account component is the nonlogged account-scope hash, never the raw
/// iCloud user record id.
public struct ReminderIdentifier: Hashable, Sendable {
    public let accountScope: String
    public let householdID: UUID
    public let itemID: UUID
    public let kind: ReminderKind

    public init(accountScope: String, householdID: UUID, itemID: UUID, kind: ReminderKind) {
        self.accountScope = accountScope
        self.householdID = householdID
        self.itemID = itemID
        self.kind = kind
    }

    public var rawValue: String {
        "account.\(accountScope).household.\(householdID.uuidString).item.\(itemID.uuidString).\(kind.rawValue)"
    }

    /// Parses structurally rather than by prefix, so one scope can never match
    /// another that merely begins with the same characters.
    ///
    /// The fixed tail is matched from the end and everything between `account.`
    /// and it is the scope, so an identifier round-trips even if the scope
    /// itself contains the separator. A scope that could not be parsed back
    /// would strand its reminders in Notification Center forever.
    public init?(parsing raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 7, parts[0] == "account" else { return nil }
        let tail = parts.suffix(5)
        let scope = parts[1..<(parts.count - 5)].joined(separator: ".")
        guard tail[tail.startIndex] == "household", tail[tail.startIndex + 2] == "item",
              !scope.isEmpty,
              let householdID = UUID(uuidString: String(tail[tail.startIndex + 1])),
              let itemID = UUID(uuidString: String(tail[tail.startIndex + 3])),
              let kind = ReminderKind(rawValue: String(tail[tail.startIndex + 4]))
        else { return nil }
        self.init(accountScope: scope, householdID: householdID, itemID: itemID, kind: kind)
    }
}

/// Which reminders one cleanup or reconciliation covers.
public enum ReminderScope: Hashable, Sendable {
    case account(String)
    case household(accountScope: String, householdID: UUID)

    public func contains(_ identifier: ReminderIdentifier) -> Bool {
        switch self {
        case .account(let scope):
            identifier.accountScope == scope
        case .household(let scope, let householdID):
            identifier.accountScope == scope && identifier.householdID == householdID
        }
    }
}

public struct ReminderRequest: Hashable, Sendable {
    public let identifier: ReminderIdentifier
    public let fireDay: InventoryDay
    public let hour: Int

    public init(identifier: ReminderIdentifier, fireDay: InventoryDay, hour: Int) {
        self.identifier = identifier
        self.fireDay = fireDay
        self.hour = hour
    }
}

/// A reminder the system currently holds. Identifiers stay raw because pending
/// requests can include ids Tridge did not write.
public struct ScheduledReminder: Hashable, Sendable {
    public let identifier: String
    public let fireDay: InventoryDay
    public let hour: Int

    public init(identifier: String, fireDay: InventoryDay, hour: Int) {
        self.identifier = identifier
        self.fireDay = fireDay
        self.hour = hour
    }
}

public struct ReminderDiff: Equatable, Sendable {
    public let add: [ReminderRequest]
    /// Same identifier, different fire date or hour — rescheduled in place.
    public let update: [ReminderRequest]
    public let remove: [String]

    public var isEmpty: Bool { add.isEmpty && update.isEmpty && remove.isEmpty }
}

/// The pure desired-versus-scheduled reminder diff. The Apple adapter applies
/// it; every rule about *which* reminders should exist lives here.
public enum NotificationPlan {
    /// How far ahead the warning fires.
    public static let warningLeadDays = 2

    public static func desiredRequests(items: [InventoryItemSnapshot], accountScope: String,
                                       householdID: UUID, hour: Int, today: InventoryDay,
                                       currentHour: Int) -> [ReminderRequest] {
        var requests: [ReminderRequest] = []
        for item in items {
            for kind in ReminderKind.allCases {
                let lead = kind == .pre ? -warningLeadDays : 0
                guard let fireDay = item.expiryDay.adding(days: lead),
                      fireDay > today || (fireDay == today && hour > currentHour)
                else { continue }
                let identifier = ReminderIdentifier(accountScope: accountScope,
                                                    householdID: householdID,
                                                    itemID: item.id, kind: kind)
                requests.append(ReminderRequest(identifier: identifier, fireDay: fireDay,
                                                hour: hour))
            }
        }
        return requests.sorted { $0.identifier.rawValue < $1.identifier.rawValue }
    }

    /// Compares the desired set against what is scheduled, touching only the
    /// requests inside `scope`.
    public static func diff(desired: [ReminderRequest], pending: [ScheduledReminder],
                            scope: ReminderScope) -> ReminderDiff {
        let inScope = pending.filter { reminder in
            ReminderIdentifier(parsing: reminder.identifier).map(scope.contains) ?? false
        }
        let scheduledByIdentifier = Dictionary(inScope.map { ($0.identifier, $0) },
                                               uniquingKeysWith: { first, _ in first })
        let wanted = desired.filter { scope.contains($0.identifier) }

        var add: [ReminderRequest] = []
        var update: [ReminderRequest] = []
        for request in wanted {
            guard let scheduled = scheduledByIdentifier[request.identifier.rawValue] else {
                add.append(request)
                continue
            }
            if scheduled.fireDay != request.fireDay || scheduled.hour != request.hour {
                update.append(request)
            }
        }

        let wantedIdentifiers = Set(wanted.map(\.identifier.rawValue))
        let remove = inScope.map(\.identifier).filter { !wantedIdentifiers.contains($0) }
        return ReminderDiff(add: add.sorted { $0.identifier.rawValue < $1.identifier.rawValue },
                            update: update.sorted { $0.identifier.rawValue < $1.identifier.rawValue },
                            remove: remove.sorted())
    }

    /// Selects the identifiers belonging to an obsolete account or household —
    /// used for pending requests and for alerts already in Notification Center.
    public static func identifiers(in existing: [String], scope: ReminderScope) -> [String] {
        existing.filter { raw in
            ReminderIdentifier(parsing: raw).map(scope.contains) ?? false
        }.sorted()
    }
}
