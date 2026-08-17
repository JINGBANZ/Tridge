# Require manual selection after invitation acceptance

Accepting and importing a Household adds it to the Household list without changing the Active
Household. The Household member selects it explicitly. Warm and cold CloudKit invitation delivery
still use the same validated acceptance route, and already-accepted metadata is never accepted
again.

If Tridge terminates after server acceptance but before shared-record import, normal CloudKit import
later makes the Household appear in the list. If it terminates before acceptance, the user reopens
the invitation. No external pending-invitation file, account/zone hash, phase machine, or crash-safe
auto-selection intent is persisted.

Automatic selection is a convenience rather than a data-integrity requirement. Manual selection
removes substantial account-binding and crash-recovery machinery while keeping accepted Inventory
safe and discoverable.
