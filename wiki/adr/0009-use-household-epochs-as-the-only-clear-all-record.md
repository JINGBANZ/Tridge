# Use Household epochs as the only Clear All record

Clear All inserts one immutable `HouseholdClearRecord` whose parents are the complete current causal
frontier. It does not append item-level `cleared` StockChanges. The reduced Household frontier alone
determines which purchase roots remain current.

An unconditional item-level clear marker can incorrectly close a root that is also supported by a
concurrent branch the clearing device has not imported yet. Adding causal scope to that redundant
marker would duplicate the epoch protocol. Removing it makes the model smaller while preserving the
selected rule: a clear suppresses prior contexts, concurrent clear branches coexist, and a later
clear that has imported both branches supersedes both.

Explicit item deletion remains a permanent `deleted` StockChange fanned across the linked component.
Clear All remains exportable through its Household clear records and is not privacy erasure.
