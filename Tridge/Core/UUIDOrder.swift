import Foundation

/// UUID byte-order comparison — the deterministic tie-break shared by every
/// household member.
///
/// The sharing contract picks canonical members, sorts stock operations, and
/// encodes epoch sets "by UUID byte order". Peers reduce independently, so the
/// ordering has to be a property of the bytes rather than of a locale-sensitive
/// string comparison. `UUID` is not `Comparable`, and conforming it here would
/// impose that ordering on every caller in the app, so this stays a namespace.
public enum UUIDOrder {
    public static func isBefore(_ lhs: UUID, _ rhs: UUID) -> Bool {
        withUnsafeBytes(of: lhs.uuid) { left in
            withUnsafeBytes(of: rhs.uuid) { right in
                for index in 0..<16 where left[index] != right[index] {
                    return left[index] < right[index]
                }
                return false
            }
        }
    }

    public static func sorted<S: Sequence>(_ ids: S) -> [UUID] where S.Element == UUID {
        ids.sorted(by: isBefore)
    }

    public static func smallest<S: Sequence>(_ ids: S) -> UUID? where S.Element == UUID {
        ids.min(by: isBefore)
    }
}
