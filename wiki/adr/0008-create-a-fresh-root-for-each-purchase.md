# Create a fresh root for each purchase

Every confirmed manual-add or receipt purchase creates a new hidden physical item root, stamps it
with the Household's complete current causal frontier, and attaches that purchase's `acquired`
StockChange to it. Exact-name active roots are then linked by the existing permanent-merge
projection, so this implementation detail does not create duplicate rows in the UI.

Appending a purchase to an older root would inherit only that root's creation frontier. After
concurrent Clear All branches, a later branch-local clear could then suppress stock bought by a
device that had already observed another surviving branch. Giving each purchase its own root records
the necessary causal context without adding frontier fields to every StockChange.

This choice retains more physical history records, but it is simpler than a per-event causal schema
and preserves every purchase through the already-selected merge projection.
