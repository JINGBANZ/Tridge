# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page.

## Current phase

**Household sharing is implemented end to end in the repository and is waiting on
live CloudKit acceptance.** Steps 1–7 of
[`household-sharing.md`](./household-sharing.md) → *Implementation sequence* are
done (issues #56–#73); step 8 is the two-account matrix on real hardware, which
needs the external provisioning in [`release-handoff.md`](./release-handoff.md).

The app now runs entirely on Core Data + CloudKit. `TridgeApp` builds one
`AccountSessionCoordinator`, and `RootView` renders its launch states; nothing in
the runtime opens a model context of its own. SwiftData survives only inside the
one-time archive reader (`Tridge/Persistence/LegacyFridgeItem.swift` +
`LegacyInventoryArchive.swift`), which reads through a throwaway copy when the
archive predates the shipping schema, so the file the user can still choose to
erase survives byte for byte.

Every Inventory action is a repository command against the Active Household, and
SwiftUI reads only value snapshots. Remote history is consumed per store with an
independent cursor that advances only after the batch has been applied. Reminders
and the badge are a diff over `NotificationPlan`, retired by exact account and
Household prefix. Settings opens a Household screen that lists every fridge with
its ownership and sync state; owners can rename, invite, stop sharing while
keeping a copy, and delete (with CloudKit absence verified for an unshared
fridge), members can leave, and everyone can export. Zone loss and encrypted-key
resets are told apart and recovered from. There is no Manage Sharing UI, no
individual-member removal, no public or read-only invitation, and no force-sync
button.

What remains is external: create `iCloud.com.tridge.app` and refresh
capabilities/provisioning, initialize the development schema once from a Debug
build, supply two iCloud accounts and devices, run the two-account matrix,
promote that schema, and ship the separate privacy-policy PR immediately before
distribution. Until the container exists the **TestFlight lane cannot archive**;
unsigned simulator builds and CI are unaffected.

Separately, the scan worker's production posture is implemented and tested in the
repo; its existing release-owner provisioning remains:

1. Create the `DEVICE_KV` namespace and paste its id into `server/wrangler.jsonc`
   (`wrangler kv namespace create DEVICE_KV`).
2. Set the worker secrets: `OPENAI_API_KEY` (budget-capped), `APPLE_TEAM_ID`, and
   `SCAN_API_TOKEN`. See `server/README.md` → Deploy.
3. Connect **Cloudflare Workers Builds** (dashboard → worker → Settings → Builds;
   root `server`, watch paths `server/**`).
4. Verify end-to-end: a **TestFlight** (Release) build scans against the worker on
   a real iPhone — App Attest can't run on the Simulator.

## Next action

**Household sharing progress is tracked in GitHub issues, not here.** Every agent
ticket through #73 is implemented; #74 and #75 are the two `ready-for-human`
tickets, and they are exactly the handoff above. Product, architecture, recovery,
and privacy-boundary decisions are closed in the contract; a coding agent should
not redesign them.

## Built

- `design/fridge-design.html` — the complete v2 design & build spec (mocks, tokens, screens,
  schema, LLM contract, acceptance criteria).
- `Package.swift` + `Tridge/Core/` — Linux-testable FridgeCore: LLM receipt-JSON parsing incl. the
  per-item `storage` guess (`ReceiptParsing.swift`), the curated `ItemID` vocabulary + shared enums
  + the derived `FoodCategory` mapping (`Types.swift`), urgency rules (`Urgency.swift`), the
  item-identity key
  (`NameKey.swift`), search ranking (`NameSearch.swift`),
  and name→art inference (`ArtInference.swift`). The scan-API client
  (`../Services/ProxyLLMService.swift`) lives here too so the smoke test can drive it on Linux.
- The household-sharing **pure contracts** (step 1 of the implementation sequence), also in
  `Tridge/Core/` and carrying no Core Data, CloudKit, or SwiftUI dependency: civil calendar days
  (`InventoryDay.swift`), the shared byte-order tie-break (`UUIDOrder.swift`), value snapshots plus
  validated record mapping and content-free integrity findings (`InventorySnapshots.swift`),
  commands/errors/quantity parsing and the same-name purchase metadata planner
  (`InventoryCommands.swift`), the immutable stock projection (`StockReducer.swift`), permanent
  exact-name convergence (`ItemGroupReducer.swift`), the causal Clear All frontier
  (`InventoryEpochReducer.swift`), Active Household choice (`HouseholdSelection.swift`), the
  desired-vs-scheduled reminder diff (`NotificationPlan.swift`), the account-scope digest that
  store paths and defaults keys hang from (`AccountScope.swift`), and the archived-row → purchase
  mapping every legacy row is validated through (`LegacyInventoryImport.swift`), and the versioned,
  privacy-filtered export document (`InventoryExport.swift`). The repository, the sharing and
  lifecycle layers, and the SwiftUI views all read them.
- `Tridge/App/` + `Tridge/Sharing/` — step 2's account session (issue #60):
  `AccountSession.swift` (the generation and the pre-load/loaded-store contexts every
  account-bound call carries),
  `AccountTaskRegistry.swift` (an actor that admits work for one generation, then closes admission,
  cancels, and **awaits** every operation before its stores may be removed — cancellation alone
  cannot stop a `context.perform` save), `SyncSession.swift` + `Sharing/StoreScopedSyncMonitor.swift`
  (observation installed during `prepareSession` before any store load, events buffered until the two
  loaded identifiers are known, and a completion accepted only when its own start was — so account
  A's late import cannot settle account B's state), `BootstrapBarrierStore.swift` (the
  `initialPrivateImportSucceeded` marker, keyed by account scope *and* private-store identifier), and
  `AccountSessionCoordinator.swift`, which sequences all of it and gates creating `My Fridge` on a
  successful first private import for an empty cache. `ActiveHouseholdStore.swift` +
  `Persistence/HouseholdSnapshots.swift` run the deterministic Active Household fallback over
  validated record snapshots, persist only the account-scoped UUID, and re-run selection when the
  barrier opens — so a Household that arrives in the first import is selected rather than
  duplicated. The reducer and registry are Foundation-only and run under Linux `swift test`; the
  coordinator, monitor, and selection are covered by `TridgeTests`. The coordinator owns one
  `HouseholdSession` per generation, which is the only inventory state SwiftUI sees.
- `Tridge/App/LegacyInventoryUpgrade.swift` + `UpgradeMarkers.swift` +
  `Tridge/Persistence/LegacyInventoryArchive.swift` + `LegacyInventoryMigration.swift` — the
  one-time upgrade off the shipping SwiftData build (issue #61), which finishes step 2.
  `UpgradeMarkers` keeps cleanup, migration completion plus its destination account/Household,
  notice acknowledgement, and persistence generation as independent installation-wide markers
  (legacy *erasure* has none — the archive files are the record). `LegacyInventoryUpgrade` clears
  every pending and delivered Tridge notification plus the badge before iCloud is checked, so a
  signed-out or restricted upgrade still stops notifying; `LegacyInventoryArchive` then opens the
  exact `Application Support/default.store` read-only with CloudKit mirroring off and returns only
  `active` rows, never receipt text. The whole set is validated through one captured calendar
  before anything is written, and `PersistenceController.importLegacyInventory` writes each row as
  a fresh frontier-stamped purchase root plus one `acquired` operation in a single private-store
  transaction, keyed by the legacy UUID so a retry recognizes what it already wrote and a
  conflicting payload is an integrity error. The destination is the account's first *owned*
  Household, created only once the bootstrap barrier has opened, and the Active Household is never
  switched. The coordinator drives the upgrade, then re-reads the migrated rows into the open
  session and persists their exact-name merge claims. `RootView` shows the one-time notice until
  Continue is tapped, and a failed migration is a retryable alert rather than a launch state.
- `Tridge/Persistence/CoreDataInventoryRepository.swift` + `InventoryProjection.swift` +
  `DuplicateReconciler.swift` + `Tridge/App/HouseholdSession.swift` — step 3's purchase path and
  snapshot projection (issue #62). `InventoryProjection` validates one Household's records into
  values and runs the three Core reducers over them, so a corrupt row is reported and skipped rather
  than repaired, deleted, or allowed to hide its neighbours. `CoreDataInventoryRepository` resolves
  the Household's store (private means owned, shared means received), checks CloudKit capability
  immediately before mutating through an injectable `StoreCapabilityChecking` seam, assigns every
  inserted record to that store, and saves a whole manual add or receipt in one transaction: one
  fresh frontier-stamped purchase root plus one `acquired` operation per row, with the preallocated
  command ids that make an identical retry a no-op and a conflicting payload an integrity error. A
  same-name purchase copies the established canonical metadata and applies only the fields the user
  explicitly edited to the canonical member resolved after insertion. `DuplicateReconciler` then
  persists the exact-name claims the projector already applied in memory — add-only, never moving or
  deleting a history, and idempotent because duplicate claims have the same union effect.
  `HouseholdSession` is the main-actor observable that holds the Active Household's `items` and
  `purchaseHistory` snapshots plus the content-free failure a refused command surfaces while the
  user's draft stays open; it also owns the local quiescence barrier every lifecycle transition
  takes before it copies or purges. `AccountSessionCoordinator` owns one per generation and
  invalidates it before the stores drain. `PreviewData.seedPurchases` makes the debug seed an
  ordinary confirmation.
- `Tridge/Persistence/InventoryCommandWriter.swift` — the rest of the Inventory commands (issue
  #63): metadata edits landing only on the group's lowest-id canonical member, quantity as an
  immutable `adjusted` operation measured against what the editor could see, eat and toss appending
  `-1`, Delete fanning one stable terminal payload across every currently linked member, Clear All
  writing one full-parent-frontier barrier and replaying that exact record on retry, and owner-only
  Household rename. `HouseholdFetch` keeps every lookup confined to one Household and one store, and
  `CommandContext` gives every command the same shape: serialized, capability-checked immediately
  before mutating, store-assigned, saved once.
- `Tridge/Persistence/HistoryTokenStore.swift` + `PersistentHistoryProcessor.swift` — remote history
  (issue #64). One cursor per persistent-store identifier, scoped by account hash; an actor that
  fetches after that store's token, merges object-id changes into the view context, reconciles
  duplicates for every affected Household, refreshes the session, and only then archives the token,
  so an interrupted pass repeats. App-authored transactions are filtered out of the effects but
  still advance the cursor.
- `Tridge/Sharing/HouseholdSharingService.swift` + `HouseholdShareItem.swift` +
  `ShareInvitationRouter.swift` + `AppDelegate.swift` + `ShareTitleRetryStore.swift` — invitations
  (issue #67). The service creates or refreshes a Household's `CKShare`, reconciles its title before
  every invitation, purges zones, captures CloudKit record ids, and reads their absence back.
  `HouseholdShareItem` exports the already-saved share with `.specifiedRecipientsOnly` and
  `.readWrite`. The router is the single entry point for warm and cold scene delivery: it checks the
  container, holds metadata in memory for this process only, accepts only `.pending`, and sends
  `.removed`/`.unknown` down a reopen path. The retry store records a title write that failed, so
  Send Invite writes it again before it will present anything.
- `Tridge/Sharing/HouseholdLifecycleTransition.swift` +
  `Tridge/Persistence/PreservedCopyWriter.swift` + `HouseholdGraphRemoval.swift` — the crash-safe
  owner transitions (issues #69, #71, #72). One account-scoped transition at a time, recorded with
  the phase that proves what has already happened, resumed before normal Household selection. Stop
  Sharing and zone recovery copy each active logical group's canonical metadata into a fresh private
  Household with one `preserved` operation, verify the copy through the store, then purge; private
  deletion captures record ids before mutating and confirms their absence after the next successful
  export.
- `Tridge/App/HouseholdRecovery.swift` — the user-facing decision for a deleted zone or an
  encrypted-key reset (issue #72), kept apart in wording as well as in handling: an owner is asked
  before anything local is purged, a member is not, and neither message names a zone or a record.
- `Tridge/Persistence/InventoryExporter.swift` + `LegacyArchiveEraser.swift` — the data-rights
  actions (issue #70). The exporter writes the whole history, current and retired, to a temporary
  file; the eraser destroys exactly the archived base plus its WAL and SHM sidecars, refusing a
  link, a directory, or anything under `HouseholdSharing/`.
- `Tridge/Persistence/` — step 2's persistence stack: the CloudKit-compatible model
  (`TridgeModel.xcdatamodeld` + hand-written `ManagedObjects/*Record` classes, with encryption
  enabled on user-content fields before schema promotion) and `PersistenceController.swift`, which
  opens one account's private and shared stores under one model, exposes the stack only after
  **both** load, tears a half-open stack down into a retryable error rather than a `fatalError`, and
  owns store routing plus the view/`app.inventory`/`app.reconcile` contexts. `Tridge/App/` adds
  `AccountIdentity.swift` (validated iCloud account → hashed scope; the raw record id never leaves
  it) and `LaunchState.swift`. `Tridge/Tridge.entitlements` plus the `CKSharingSupported` and
  remote-notification Info.plist settings declare the capabilities. Everything in the runtime writes
  and projects through this stack. A `#if DEBUG`-only `-initializeCloudKitSchema` launch argument is
  the one path to `initializeCloudKitSchema`, and it never runs on an ordinary launch.
- `Tests/FridgeCoreTests/` — parsing (incl. fenced/prose-wrapped output), urgency
  thresholds, name-key, art-inference, and search-ranking tests, plus the
  household-sharing contract tests (civil days, byte order, record validation, command validation
  and receipt-text discard, purchase planning and household-scoped grouping eligibility,
  legacy-row validation and civil-day conversion,
  stock order-independence/idempotency/overflow/zero-revival/deletion,
  claim-order-independent convergence, causal clear branches, Household selection, account-scope
  validation, reminder diffs, and export completeness with restricted fields absent); all pass via
  `swift test`.
- `TridgeTests/` — the Apple-platform bundle for what Linux cannot compile: Core Data model rules
  (optional/defaulted attributes, inverses, delete rules, indexes, the exact CloudKit-encrypted set,
  no constraints or transformables), two isolated stores per account, store assignment and
  cross-store rejection, retryable load failure, context confinement, the built app's sharing
  capabilities, the store/generation isolation of `StoreScopedSyncMonitor`, and the coordinator's
  launch states, bootstrap gate, Active Household selection, and account transition (an account
  change mid-load releases the stores that generation opened; registered work finishes before its
  stores are removed). It also covers the legacy upgrade: signed-out cleanup exactly once, active
  rows landing in the first owned Household as frontier-stamped roots, an identical replay writing
  nothing new, a conflicting or corrupt row failing the whole write while the archive survives
  untouched, a second account never inheriting the archive, and notice acknowledgement surviving
  termination independently. `InventoryRepositoryTests` and `HouseholdSessionTests` cover the
  purchase path: store routing into the owning or receiving store, the frontier stamp and single
  `acquired` operation each root carries, atomic multirow saves, identical/partial/conflicting
  retries, same-name convergence with copied canonical metadata and explicit-edit application,
  durable idempotent merge claims that move no history, a late member operation moving the
  aggregate, superseded and post-clear causal contexts, capability denial and stale Household
  selection writing nothing, corrupt rows being omitted without hiding valid inventory, and receipt
  text never leaving the review draft. `InventoryCommandTests` covers the remaining commands;
  `PersistentHistoryTests` the per-store cursors and author filtering; `ReminderReconcilerTests` the
  notification diff and scope retirement; `HouseholdScreenTests` ownership labels and local
  selection; `ShareInvitationTests` and `HouseholdSharingTests` invitation routing and the owner's
  share path; `HouseholdLeaveTests`, `StopSharingTests`, `HouseholdDeletionTests`, and
  `HouseholdRecoveryTests` the lifecycle transitions and their crash points; and
  `HouseholdDataRightsTests` export completeness and exact-path erasure. Runs in macOS CI on a
  simulator.
- `Tests/ReceiptScanSmokeTests/` — live regression harness: fixture receipt images +
  fuzzy `expected.json` inventories (see its `Fixtures/README.md`), sent through the deployed
  worker via `ProxyLLMService`; local-only — the bearer token comes from the environment or a
  gitignored `.env` (copy `env.sample`, `SCAN_API_TOKEN`; override the target with `BACKEND_URL`),
  skips without one, and is never run in CI. Ships three synthetic fixtures (clean, faded-thermal,
  crooked low-res photo); gitignored `Fixtures/private/` for personal receipts.
- `Tridge/` — the app (iOS 18+): `App/` (`TridgeApp.swift` builds the one coordinator and
  `RootView.swift` renders its launch, account, migration-notice, and recovery states;
  `AppTheme.swift` design tokens, preview fixtures),
  a single-tap add menu on the scan button (camera scan where a document camera exists ·
  photo-library import · "Type to add" manual entry via `Views/Home/ManualAddSheet.swift`, which
  needs no scan at all; debug builds add `Resources/SampleReceipt.jpg` and a "Seed the App" action
  that inserts the preset `PreviewData` inventory with no LLM call), `Core/AppLog.swift` +
  Settings → Copy diagnostics as the tester feedback loop,
  `Models/Artwork.swift` (artKey → art lookup), `Services/`
  (`LLMService.swift` protocol + errors, `ProxyLLMService.swift` scan-API client with a pluggable
  `ScanRequestAuthorizer`, `AppAttestAuthorizer.swift` on-device App Attest, `ScanAPIConfig.swift`
  single worker URL (build-config Debug/Release split deferred until a prod worker exists), `ReceiptScanner.swift` VisionKit
  camera, `NotificationService.swift` — the reminder diff adapter and its legacy cleanup,
  `Haptics.swift`), `Views/`
  (Home grid + drag-to-consume + Apple Music–style capsule name search, hidden at rest and revealed
  by pulling the grid down + the header filter button/sheet — Storage +
  Food Category filters via `Views/Home/FilterSheet.swift`, hidden on an empty fridge, search
  applying on top of the filters — scan flow + review sheet with per-row Food Category/Storage
  chips, item detail + art picker, settings — incl. an emoji-free mode that swaps the home grid for
  a name-row list (`Views/Home/ItemRow.swift`) and hides item art across the add/review/detail
  sheets while art keys stay stored — and `Views/Household/HouseholdScreen.swift`, the fridge list
  with its ownership labels, sync state, owner and member actions, and data controls). Saving —
  scanned or typed — creates a fresh purchase root that projects together with a matching active
  item of the same name instead of duplicating the row
  (`design/item-grouping-search.html`); manual add has quick-fill history chips above the name field
  and automatic art (remembered → inferred → tap-to-pick). Item detail and manual add render the
  same label-left / value-right field set (`Views/Shared/ItemFormRows.swift`); a saved Item Name is
  read-only there (ADR 0005).
- `Tridge.xcodeproj` — hand-written project (synchronized folder group) + shared scheme;
  see the decision log for why it's hand-authored.
- `.github/workflows/ci.yml` — Linux `swift test`; server typecheck + Vitest; release-lane syntax;
  Xcode 26/iOS 26 SDK `swift test` + a Debug simulator build with an iOS 18 deployment target
  (compile-only gate, `CODE_SIGNING_ALLOWED=NO`) + the `TridgeTests` bundle on the runner's first
  available iPhone simulator.
- `.github/workflows/testflight.yml` + `fastlane/` (`Fastfile`, `Appfile`) + `Gemfile`/
  `Gemfile.lock` (Fastlane exactly pinned to 2.237.0) — the
  manual TestFlight release lane: `workflow_dispatch` imports a reusable Apple Development identity
  from GitHub secrets, builds a signed Release IPA, and uploads it via fastlane's
  `upload_to_testflight`; the archive
  retries once when Apple's provisioning service transiently fails, before any upload begins. Signing
  hands the App Store Connect API key to `xcodebuild` itself via `-authenticationKey*` (gym does
  not forward it), so the workflow decodes the `.p8` to a file first; the key must have the
  **Admin** role because cloud-managed distribution signing is Admin-only. Needs the `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`, and two `APPLE_DEVELOPMENT_CERT_*` repo secrets
  (setup in `README.md` → "On your iPhone (TestFlight)"). Reusing the development identity prevents
  ephemeral runners from exhausting Apple's certificate quota; no certificate is stored in the
  repo. Build number is the GitHub run number; `ITSAppUsesNonExemptEncryption=NO`
  is set so builds skip the export-compliance prompt. Runs on `macos-26` (Xcode 26 / iOS 26 SDK —
  Apple's current upload minimum; `macos-15`/Xcode 16 is rejected). One more account prerequisite
  beyond the Admin key: the team needs **one registered device**, or automatic signing can't mint
  the archive's provisioning profile. Verified end-to-end — a build uploaded to TestFlight on
  2026-07-09.
- `Tridge/Assets.xcassets/AppIcon` (1024² placeholder — replace with real art) and
  `Tridge/PrivacyInfo.xcprivacy` (declares the app's `UserDefaults`/`@AppStorage` required-reason
  API, `CA92.1`) — both required for App Store Connect upload validation (a missing icon hard-fails
  the upload; the privacy manifest is a required-reason compliance gap).
- `AGENTS.md` / `CLAUDE.md` + `wiki/agents/` — agent instructions and repository-specific Matt-skill
  mappings; shared-rules block syncs from JINGBANZ/rules.
- `wiki/adr/` — numbered ADRs for new load-bearing decisions; `wiki/decisions.md` preserves the
  earlier running decision log.
- `.github/workflows/sync-shared-rules.yml` — weekly shared-rules sync (stub → JINGBANZ/workflows).
- `.github/workflows/claude.yml`, `.github/workflows/claude-code-review.yml` — @claude mentions and
  automatic PR review (need the `CLAUDE_CODE_OAUTH_TOKEN` secret via `/install-github-app`).
- `server/` — the receipt-scan API: a Cloudflare Worker (TypeScript) exposing
  `POST /v1/receipt-scan` (raw JPEG in, `ParsedReceipt` JSON out) that holds the OpenAI key as
  a worker secret; per-IP rate limit → client auth → strict input validation → sanitized errors.
  Client auth is Apple App Attest (`src/appattest.ts`: attestation registration via
  `/v1/attest/challenge` + `/v1/attest`, per-scan assertion, per-device quota — device keys/counters
  in the `DEVICE_KV` namespace, crypto via the `node-app-attest` library) with a static bearer token
  as a fallback for the local smoke harness. `store:false` uniformly. It also serves the public
  privacy policy at `/privacy`. One worker deploys today
  (`tridge-scan-api-test`, serving both Xcode-dev and TestFlight builds); the config is env-driven so
  a dedicated prod worker + isolated key is additive later. It is the single home of the receipt
  prompt + JSON schema. Vitest + tsc suite (`npm run typecheck && npm test`, incl. App Attest
  verification against known-good vectors); CI gates PRs; deploys go through Cloudflare Workers
  Builds (git integration), not CI. Setup/API: `server/README.md`.
- `wiki/` — this design-docs set.
- `wiki/household-sharing.md` — the independently reviewed implementation contract for Apple
  capabilities, exact account-scoped private/shared persistence, repository commands, stock/delete
  and same-name item convergence, inventory epochs, store-scoped sync monitoring,
  Household/invitation/lifecycle UI, notification reconciliation, export/deletion, owner-only gates,
  and the automatic no-uninstall active-inventory migration.
- `wiki/release-handoff.md` — the external steps only a release owner can take: the Apple container
  and capabilities, the one-time development-schema run, two iCloud accounts, the two-account
  matrix, schema promotion, and the exact proposed privacy-policy and App Store disclosure copy.

## Not yet built

- **Live CloudKit acceptance** (issues #74, #75): the container, the development
  schema, two iCloud accounts and devices, the two-account matrix, schema
  promotion, the privacy-policy release PR, and a TestFlight distribution. See
  [`release-handoff.md`](./release-handoff.md).
- Owner-only provisioning to bring the scan worker live: create the `DEVICE_KV`
  namespace, set the secrets (`OPENAI_API_KEY`, `APPLE_TEAM_ID`,
  `SCAN_API_TOKEN`), connect Cloudflare Workers Builds. See "Next action" and
  `server/README.md` → Deploy.
- A dedicated production worker + isolated budget-capped key (separate URL) —
  deferred; the code is ready for it (`server/README.md` → "Adding a production
  worker later").
- Verification of the spec's acceptance checklist on a test build: a local
  Simulator covers the simulator-safe items; the camera items and a live App
  Attest scan need a TestFlight build on a physical iPhone.
