# Treat zero quantity as a revivable projection

A logical item whose reduced quantity is zero is hidden, but zero is not a durable terminal marker.
A delayed valid StockChange from an offline Household member may make the globally reduced quantity
positive and show the item again. This reflects that the synchronized history was never actually at
zero once every operation was known.

A new local purchase never pays down or appends to a locally zero group; it creates the fresh
purchase root defined by ADR 0008. A stale detail draft is rejected if its target no longer projects
as active. Explicit Delete, not zero, is the permanent item-level terminal action.

Making zero globally terminal would require another causal depletion protocol and could discard a
legitimate delayed operation. The first sharing rollout accepts the simpler revivable projection.
