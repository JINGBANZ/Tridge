# Preserve canonical metadata on same-name purchases

When a new purchase matches an active logical item by normalized name, its fresh purchase root
copies that logical item's canonical name, art, storage, Purchase Day, Expiry Day, and expiry
source.
This prevents a newly generated lower UUID from changing displayed metadata merely by becoming the
canonical physical member.

If the user explicitly changes an editable art, storage, or Expiry Day field in Review or manual
add, the same atomic purchase command applies only those intentional changes to the canonical member
resolved after insertion. Quantity comes from the new root's `acquired` operation. Unedited scan
guesses do not overwrite established metadata, and a saved Item Name remains immutable.

Replacing the complete metadata form on every purchase would let a scan guess overwrite a trusted
value. Ignoring explicit edits would discard user intent. Copy-then-apply-explicit-fields preserves
both the existing UI behavior and the deterministic canonical-member rule.
