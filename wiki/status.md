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
[`household-sharing.md`](./household-sharing.md), but no implementation. Its final safety details
stay inside the existing boundaries: owner-stop recovery is armed before Apple's management UI,
invitation restrictions use minimal system options with secure defaults, explicit legacy erasure
removes only exact validated remnants, and pending invitation keys hash their CloudKit zone
identity. The
plain-language graph and component map are in
[`household-sharing-overview.html`](../design/household-sharing-overview.html). The contract uses
Apple-native CloudKit Sharing with account-isolated private/shared Core Data stores, immutable
stock/delete events behind a repository, revision-guarded merge claims that make concurrent exact-name active
items one lossless logical row without trapping concurrent renames, causal inventory frontiers that
make Clear All cover unseen offline rows without discarding additions after a concurrent clear,
system invitation/participant UI, and real export/deletion behavior. Sync observation starts before
store loading, buffers setup/import events, then reduces only events for the activated account
session's two store identifiers; an empty fresh cache cannot bootstrap before its initial private
import. Invitation-selection intent is durable before CloudKit acceptance, and account changes
invalidate and drain generation-bound work before removing stores, so a crash or late callback
cannot lose the invited household or expose the prior account. Persistent history, sharing,
authorization, and inventory convergence stay application-owned. It keeps the scan Worker outside
the inventory data plane and upgrades installed test builds automatically to a fresh shareable
inventory without requiring users to uninstall. The authoritative HTML spec delegates sharing-
release persistence, lifecycle, reset, and verification details to that page and specifies Core
Data/CloudKit for the sharing build.

## Next action

Implement household sharing in the fixed order under
[`household-sharing.md`](./household-sharing.md) → *Implementation sequence*: pure contracts/tests →
exact Core Data model and account-scoped two-store launch → repository migration of every inventory
path plus lossless duplicate reconciliation and clear epochs → store-scoped sync status and
history/notifications (including pre-load event buffering, initial-import bootstrap gating, and
obsolete delivered-alert cleanup) →
Household/invitation UI → lifecycle/export/deletion → full Gate/CI. Product, architecture, recovery,
and privacy-boundary decisions are closed there; a coding agent should not redesign them.

Live CloudKit/TestFlight completion has an explicit owner-only boundary: create/associate
`iCloud.com.tridge.app` and refresh capabilities/provisioning, supply two iCloud test accounts/
devices, promote the accepted development schema, review App Store privacy metadata, and run the
signed two-account checklist. The agent can finish code, fakes, tests, unsigned build, CI, and docs
without those actions and must report only the live acceptance as externally blocked.

Separately, the scan worker's production posture is implemented and tested in the repo; its existing
owner-only provisioning remains:

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
- `Tests/FridgeCoreTests/` — parsing (incl. fenced/prose-wrapped output), urgency
  thresholds, name-key, merge-planner, art-inference, and search-ranking tests; all
  pass via `swift test`.
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
  (compile-only gate, `CODE_SIGNING_ALLOWED=NO`).
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
- `AGENTS.md` / `CLAUDE.md` — agent instructions; shared-rules block syncs from JINGBANZ/rules.
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
  and the automatic no-uninstall reset; the subsystem itself is not implemented.

## Not yet built

- Owner-only provisioning to bring the scan worker live: create the `DEVICE_KV` namespace, set the
  secrets (`OPENAI_API_KEY`, `APPLE_TEAM_ID`, `SCAN_API_TOKEN`), connect Cloudflare Workers Builds.
  See "Next action" and `server/README.md` → Deploy.
- A dedicated production worker + isolated budget-capped key (separate URL) — deferred; the code is
  ready for it (`server/README.md` → "Adding a production worker later").
- Verification of the spec's acceptance checklist on a test build: a local Simulator covers the
  simulator-safe items; the camera items and a live App Attest scan need a TestFlight build on a
  physical iPhone.
- Household sharing implementation — specified in
  [`household-sharing.md`](./household-sharing.md), including exact model/operations/UI/lifecycle,
  revision-safe same-name merge claims, causal household clear frontiers, pre-load/current-store
  sync-session isolation, privacy/data-rights behavior, owner handoff, and the fresh-store upgrade for existing
  App Store/TestFlight installations; no sharing model, persistence stack, repository, invite flow,
  or sync reconciliation exists in code yet.
