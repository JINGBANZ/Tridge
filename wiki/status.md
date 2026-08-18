# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page.

## Current phase

v1 merged and CI green (Linux `swift test` + macOS build). Real-device testing (including the
camera) goes through a manual **TestFlight** release (`.github/workflows/testflight.yml` +
`fastlane/`); for a no-hardware UI check, run the app in a local **Simulator** from Xcode. Install
instructions are in `README.md` → "Trying the app". The app scans through the `server/` worker
(`ProxyLLMService`) and carries no OpenAI key — BYOK is fully removed. Client auth is **Apple App
Attest**: the app signs each scan with an on-device Secure Enclave key and ships no static token.
**One worker** (`tridge-scan-api-test`) serves every build (Xcode-dev + TestFlight), with `store:false`
and the full production posture (per-device quotas, sanitized errors); it also accepts a static
bearer token solely for the local smoke harness. A dedicated production worker (separate URL +
isolated OpenAI key) is deferred — the code is env-driven so it drops in additively later
(`server/README.md` → "Adding a production worker later").

Household sharing has an independently reviewed, implementation-ready contract in
[`household-sharing.md`](./household-sharing.md). Its step-1 pure contracts are implemented and
Linux-tested in `Tridge/Core/`, and step 2's exact Core Data model, account-scoped two-store stack,
and capability declarations are in `Tridge/Persistence/` with an Apple-platform `TridgeTests` bundle
running in macOS CI. The generation-bound account session that owns those stores is now built too
(`Tridge/App/AccountSessionCoordinator.swift`, `AccountTaskRegistry.swift`,
`BootstrapBarrierStore.swift`, and `Tridge/Sharing/StoreScopedSyncMonitor.swift`): sync observation
is prepared before the stores load, both stores load as one registered operation, and an empty
account cache cannot create `My Fridge` until its first private import succeeds. The repository,
sharing, lifecycle, and legacy-migration layers are not built. Its final safety details
stay inside the existing boundaries: Tridge exposes one explicit resumable owner-stop path and no
management UI, invitation restrictions use minimal system options with secure defaults, explicit
legacy erasure removes only exact validated remnants, and invitation metadata stays in memory. The
plain-language graph and component map are in
[`household-sharing-overview.html`](../design/household-sharing-overview.html). The contract uses
Apple-native CloudKit Sharing with account-isolated private/shared Core Data stores, immutable
stock/delete events behind a repository, permanent merge claims that make concurrent exact-name
active purchase roots one lossless logical row while saved names remain read-only, causal inventory
frontiers that make Clear All cover unseen offline rows without discarding additions after a
concurrent clear, system invitation UI, and real export/deletion behavior. Sync observation starts
before store loading, buffers setup/import events, then reduces only events for the activated account
session's two store identifiers; an empty fresh cache cannot bootstrap before its initial private
import. An accepted Household enters the picker without changing the active selection; termination
before acceptance requires reopening the invitation. Account changes invalidate and drain
generation-bound work before removing stores, so a late callback cannot expose the prior account.
Persistent history, sharing,
authorization, and inventory convergence stay application-owned. It keeps the scan Worker outside
the inventory data plane and migrates every active legacy item automatically into the first owned
Household without requiring users to uninstall. The authoritative HTML spec delegates sharing-
release persistence, lifecycle, migration, and verification details to that page and specifies Core
Data/CloudKit for the sharing build. The first rollout supports one installation for a Household
owner without pretending to enforce that constraint through an offline device lock.

## Next action

**Household sharing progress is tracked in GitHub issues, not here.** Each step of
[`household-sharing.md`](./household-sharing.md) → *Implementation sequence* is one ticket carrying
its own acceptance criteria and `Blocked by` links, so the next action is whichever ticket is open
and unblocked — find it with `gh issue list --state open --label ready-for-agent` and check its
blockers. This page describes what exists; the tickets say what to do next and when it is done.
Close a ticket when its criteria are met, and reference it from the PR.

At the time of writing the frontier is **#61 — Migrate active legacy Inventory without an
uninstall**, unblocked once #60 lands. Product, architecture, recovery, and privacy-boundary
decisions are closed in the contract; a coding agent should not redesign them.

Live CloudKit/TestFlight completion has an explicit external release boundary: create/associate
`iCloud.com.tridge.app` and refresh capabilities/provisioning, supply two iCloud test accounts/
devices, promote the accepted development schema, review App Store privacy metadata, and run the
signed two-account checklist. That review includes `Tridge/PrivacyInfo.xcprivacy`. The agent can
finish code, fakes, tests, unsigned build, CI, and docs without those actions and must report only
the live acceptance as externally blocked. Signed builds now request the iCloud container through
`Tridge/Tridge.entitlements`, so the **TestFlight lane needs that container created and the App ID
services enabled before it can archive again**; unsigned simulator builds and CI do not.

Separately, the scan worker's production posture is implemented and tested in the repo; its existing
release-owner provisioning remains:

1. Create the `DEVICE_KV` namespace and paste its id into `server/wrangler.jsonc`
   (`wrangler kv namespace create DEVICE_KV`).
2. Set the worker secrets: `OPENAI_API_KEY` (budget-capped), `APPLE_TEAM_ID`, and `SCAN_API_TOKEN`.
   See `server/README.md` → Deploy.
3. Connect **Cloudflare Workers Builds** (dashboard → worker → Settings → Builds; root `server`,
   watch paths `server/**`).
4. Verify end-to-end: a **TestFlight** (Release) build scans against the worker on a real iPhone —
   App Attest can't run on the Simulator.

Still open beyond that: the acceptance checklist in a local Simulator; the on-device camera
acceptance items via a TestFlight build; and, when wanted, the dedicated production worker +
isolated key.

## Built

- `design/fridge-design.html` — the complete v2 design & build spec (mocks, tokens, screens,
  schema, LLM contract, acceptance criteria).
- `Package.swift` + `Tridge/Core/` — Linux-testable FridgeCore: LLM receipt-JSON parsing incl. the
  per-item `storage` guess (`ReceiptParsing.swift`), the curated `ItemID` vocabulary + shared enums
  + the derived `FoodCategory` mapping (`Types.swift`), urgency rules (`Urgency.swift`), the
  item-identity key
  (`NameKey.swift`), merge decisions (`MergePlanner.swift`), search ranking (`NameSearch.swift`),
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
  desired-vs-scheduled reminder diff (`NotificationPlan.swift`), and the account-scope digest that
  store paths and defaults keys hang from (`AccountScope.swift`). The repository, sharing, and UI
  layers that consume them are not built yet.
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
  coordinator, monitor, and selection are covered by `TridgeTests`. Nothing consumes the session
  yet — the repository migration is step 3 (issues #62/#63).
- `Tridge/Persistence/` — step 2's persistence stack: the CloudKit-compatible model
  (`TridgeModel.xcdatamodeld` + hand-written `ManagedObjects/*Record` classes, with encryption
  enabled on user-content fields before schema promotion) and `PersistenceController.swift`, which
  opens one account's private and shared stores under one model, exposes the stack only after
  **both** load, tears a half-open stack down into a retryable error rather than a `fatalError`, and
  owns store routing plus the view/`app.inventory`/`app.reconcile` contexts. `Tridge/App/` adds
  `AccountIdentity.swift` (validated iCloud account → hashed scope; the raw record id never leaves
  it) and `LaunchState.swift`. `Tridge/Tridge.entitlements` plus the `CKSharingSupported` and
  remote-notification Info.plist settings declare the capabilities. Nothing consumes the stack yet —
  the app still runs on SwiftData until the repository migration.
- `Tests/FridgeCoreTests/` — parsing (incl. fenced/prose-wrapped output), urgency
  thresholds, name-key, merge-planner, art-inference, and search-ranking tests, plus the
  household-sharing contract tests (civil days, byte order, record validation, command validation
  and receipt-text discard, stock order-independence/idempotency/overflow/zero-revival/deletion,
  claim-order-independent convergence, causal clear branches, Household selection, account-scope
  validation, and reminder diffs); all pass via `swift test`.
- `TridgeTests/` — the Apple-platform bundle for what Linux cannot compile: Core Data model rules
  (optional/defaulted attributes, inverses, delete rules, indexes, the exact CloudKit-encrypted set,
  no constraints or transformables), two isolated stores per account, store assignment and
  cross-store rejection, retryable load failure, context confinement, the built app's sharing
  capabilities, the store/generation isolation of `StoreScopedSyncMonitor`, and the coordinator's
  launch states, bootstrap gate, Active Household selection, and account transition (an account
  change mid-load releases the stores that generation opened; registered work finishes before its
  stores are removed). Runs in macOS CI on a simulator.
- `Tests/ReceiptScanSmokeTests/` — live regression harness: fixture receipt images +
  fuzzy `expected.json` inventories (see its `Fixtures/README.md`), sent through the deployed
  worker via `ProxyLLMService`; local-only — the bearer token comes from the environment or a
  gitignored `.env` (copy `env.sample`, `SCAN_API_TOKEN`; override the target with `BACKEND_URL`),
  skips without one, and is never run in CI. Ships three synthetic fixtures (clean, faded-thermal,
  crooked low-res photo); gitignored `Fixtures/private/` for personal receipts.
- `Tridge/` — the app (iOS 18+): `App/` (entry with the one-time `normalizedName` backfill,
  `AppTheme.swift` design tokens, preview seed),
  a single-tap add menu on the scan button (camera scan where a document camera exists ·
  photo-library import · "Type to add" manual entry via `Views/Home/ManualAddSheet.swift`, which
  needs no scan at all; debug builds add `Resources/SampleReceipt.jpg` and a "Seed the App" action
  that inserts the preset `PreviewData` inventory with no LLM call), `Core/AppLog.swift` +
  Settings → Copy diagnostics as the tester feedback loop,
  `Models/` (`FridgeItem.swift` SwiftData model with the indexed `normalizedName` identity key,
  `Artwork.swift` artKey lookup), `Services/`
  (`LLMService.swift` protocol + errors, `ProxyLLMService.swift` scan-API client with a pluggable
  `ScanRequestAuthorizer`, `AppAttestAuthorizer.swift` on-device App Attest, `ScanAPIConfig.swift`
  single worker URL (build-config Debug/Release split deferred until a prod worker exists), `ReceiptScanner.swift` VisionKit
  camera, `NotificationService.swift`, `Haptics.swift`), `Views/`
  (Home grid + drag-to-consume + Apple Music–style capsule name search, hidden at rest and revealed
  by pulling the grid down + the header filter button/sheet — Storage +
  Food Category filters via `Views/Home/FilterSheet.swift`, hidden on an empty fridge, search
  applying on top of the filters — scan flow + review sheet with per-row Food Category/Storage
  chips, item detail + art picker, settings — incl. an emoji-free mode that swaps the home grid for
  a name-row list (`Views/Home/ItemRow.swift`) and hides item art across the add/review/detail
  sheets while art keys stay stored). Saving — scanned or typed — merges into a matching
  active item by normalized name instead of duplicating it (`design/item-grouping-search.html`);
  manual add has quick-fill history chips above the name field and automatic art
  (remembered → inferred → tap-to-pick). Item detail and manual add render the same
  label-left / value-right field set (`Views/Shared/ItemFormRows.swift`).
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
  and the automatic no-uninstall active-inventory migration; the subsystem itself is not
  implemented.

## Not yet built

- Owner-only provisioning to bring the scan worker live: create the `DEVICE_KV` namespace, set the
  secrets (`OPENAI_API_KEY`, `APPLE_TEAM_ID`, `SCAN_API_TOKEN`), connect Cloudflare Workers Builds.
  See "Next action" and `server/README.md` → Deploy.
- A dedicated production worker + isolated budget-capped key (separate URL) — deferred; the code is
  ready for it (`server/README.md` → "Adding a production worker later").
- Verification of the spec's acceptance checklist on a test build: a local Simulator covers the
  simulator-safe items; the camera items and a live App Attest scan need a TestFlight build on a
  physical iPhone.
- Household sharing steps 3–8, plus the legacy migration that finishes step 2 — specified in
  [`household-sharing.md`](./household-sharing.md) → *Implementation sequence*: the repository
  migration off runtime SwiftData, per-store persistent history and remote reconciliation, the
  Household/invitation UI, lifecycle and data rights, and the active-inventory migration for
  existing App Store/TestFlight installations. Steps 1 and 2's model, stores, capabilities, and
  account session exist (see "Built"); no repository, invite flow, history processing, or
  reconciliation does, and the running app still reads and writes SwiftData.
