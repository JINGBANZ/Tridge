# Support one owner installation in the first rollout

The first Household-sharing rollout supports one Tridge installation signed into a given Household
owner's iCloud account. This is a documented and tested rollout constraint, not a technically
enforced device lock. Household members use separate invited iCloud accounts; the normal two-account
owner/member collaboration remains supported.

Tridge does not add a backend, device registry, online lease, or CloudKit-based lock to enforce this
constraint. Owner lifecycle operations still close local command admission and drain already-started
writes before taking a copy or deletion snapshot. Under the supported topology, Stop Sharing cannot
race with a second owner installation to create another private copy, and verified private deletion
has no second owner cache that can later export stale or newly created records.

If the same Household owner's iCloud account runs Tridge concurrently on another installation,
duplicate personal Households, a second stop-sharing copy, or later CloudKit uploads after a
deletion are outside the first rollout's guarantees. Supporting that topology later requires a
separate design rather than pretending the current offline-first client can enforce exclusivity.
