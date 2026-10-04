# State grouping eligibility once, in PurchasePlanner

The rule that a purchase groups only with an active, unexpired item of the exact same normalized name
lives in one place: `PurchasePlanner` in `Tridge/Core/InventoryCommands.swift`. It works on the
Household's projected `InventoryItemSnapshot` rows, so zero-quantity and deleted groups are already
absent from what it is asked about, and superseded contexts are already filtered by the causal
frontier.

The sharing release makes grouping a *projection* of exact-name physical roots rather than a decision
to rewrite one row's quantity, so the rule needs a household-scoped input and an `Int64` quantity
with no product cap (ADR 0004). Keeping a second statement of the same rule against the pre-sharing
row shape would leave one of the two unreachable from the app and free to drift from the other —
and the unreachable one would still be the one a reader found first, because the contract names it.

The eligibility cases move with the rule: they are asserted against `PurchasePlanner` in
`Tests/FridgeCoreTests/InventoryCommandsTests.swift`, including diacritic-insensitive matching,
expired batches never absorbing a purchase, most-recent-wins among several matches, unnamed rows
never stacking, and multi-row saves whose review-time renames collide.
