# Tridge domain

Tridge models food inventory inside an ownership and sharing boundary. This glossary keeps product
language distinct from user-facing labels and platform terminology.

## Collaboration

**Household**:
The ownership and sharing boundary for one inventory.
_Avoid_: Fridge, account, share

**Household owner**:
The person who creates a Household and controls its invitations and lifecycle.
_Avoid_: Owner, Apple account owner

**Household member**:
A person who accepts an invitation to a Household and may edit its inventory. Household members are
trusted collaborators rather than adversarial actors.
_Avoid_: Participant, user

**Active Household**:
The Household currently selected on one installation. This selection is local to that installation.
_Avoid_: Current fridge, default household

**Accepted Household**:
A received Household whose CloudKit invitation has been accepted and imported. It appears in the
Household list but does not automatically become the Active Household.
_Avoid_: Auto-selected Household, pending invitation

**Owner installation**:
The single Tridge installation signed into a Household owner's iCloud account that is supported by
the first sharing rollout. This is an unenforced rollout constraint, not an authorization or
security mechanism.
_Avoid_: Authorized device, device lock

**iCloud account**:
The Apple account whose container-specific CloudKit identity scopes one runtime persistence
session. It is an isolation principal, not the owner of every Household visible in that session.
_Avoid_: Account owner, CloudKit owner, user

**Account scope**:
The nonlogged hash of the current iCloud account's container-specific user record name. It scopes
store paths, history tokens, the Active Household selection, and reminder identifiers. The raw
record id is never persisted or logged.
_Avoid_: Account id, user id, iCloud id

**Developer Account Holder/Admin**:
An authorized Apple Developer Program role that can provision App IDs, capabilities, containers,
or CloudKit access. This release/provisioning role is unrelated to a Household owner.
_Avoid_: Apple account owner, Household owner

## Inventory

**Inventory**:
The food stock and retained history belonging to one Household across fridge, freezer, and pantry
storage.
_Avoid_: Household, database

**Fridge**:
The user-facing label for a Household's combined inventory, including freezer and pantry items.
_Avoid_: Fridge when referring to the ownership boundary

**Purchase Day**:
The timezone-independent calendar day on which an item was acquired.
_Avoid_: Purchase time, purchase timestamp

**Expiry Day**:
The timezone-independent calendar day through which an item is expected to remain usable.
_Avoid_: Expiry time, expiry timestamp

**Item Name**:
The identity chosen for an Inventory item before it is saved. Item Names are immutable in the first
sharing release; correcting one later means deleting and adding the item again.
_Avoid_: Editable label, display name

**Purchase root**:
The hidden physical Inventory record created for one confirmed manual or receipt purchase. Every
purchase gets a root stamped with the Household's current causal frontier; compatible exact-name
roots may be presented as one logical item.
_Avoid_: Visible duplicate, quantity increment

**Logical item**:
The single Inventory row presented for a set of purchase roots joined by merge claims. Its identity
and canonical item metadata come from the lowest member id in byte order, so every device resolves
the same one.
_Avoid_: Merged item, master record

**Merge claim**:
The permanent, add-only assertion that two exact-name purchase roots are the same logical item.
Claims are never deactivated or removed, and no claim transfers or deletes a root's history.
_Avoid_: Merge, dedupe, unmerge

**Stock operation**:
One immutable record of stock moving, carrying a delta and a reason. Operations compose, so no
concurrent increment or decrement is overwritten by a scalar quantity.
_Avoid_: Quantity update, stock write

**Projected quantity**:
The nonnegative quantity calculated from a logical item's immutable stock operations. A projection
of zero hides the item but is not a permanent tombstone; a delayed valid operation may make it
positive again.
_Avoid_: Stored quantity, permanent depletion

**Canonical item metadata**:
The name, art, storage, Purchase Day, Expiry Day, and expiry source read from the lowest-id physical
member of a linked logical item. A same-name purchase copies these values; only fields explicitly
edited by the user are then applied to the canonical member.
_Avoid_: Latest-root metadata, timestamp winner

**Clear All**:
An Inventory action that advances the Household's causal inventory frontier. It does not add item-
level clear events and is not a privacy-data erasure action.
_Avoid_: Delete Household, erase history

**Inventory epoch**:
One immutable node in a Household's causal clear graph. Clear All creates a fresh epoch whose
parents are every epoch the clearing device could see.
_Avoid_: Clear timestamp, generation counter

**Inventory frontier**:
The set of epochs with no later clear naming them as a parent. Two Household members who clear while
offline produce two frontier leaves rather than a winner and a loser.
_Avoid_: Current epoch, latest clear

**Inventory context**:
The complete frontier a purchase root captured when it was created. The root stays current while at
least one captured epoch is still on the frontier, so an item added after either of two concurrent
clears survives.
_Avoid_: Epoch stamp, clear generation
