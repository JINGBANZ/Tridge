# Use canonical item metadata and field merges

The lowest-id physical member supplies a logical item's metadata, and all later art, storage, and
Expiry Day edits target that canonical member. Core Data may merge concurrent edits by property;
Tridge accepts that behavior instead of adding metadata events, Lamport clocks, or a complete-form-
winner guarantee in the first sharing release.
