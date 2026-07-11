# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page.

## Current phase

v1 merged and CI green (Linux `swift test` + macOS build). Two distribution paths exist: a
manual **TestFlight** release (`.github/workflows/testflight.yml` + `fastlane/`) for real-device
testing including the camera, and a Debug **simulator** build published as the `Tridge-simulator`
artifact and as a per-PR **Appetize** browser preview for zero-setup UI review. Install
instructions are in `README.md` → "Trying the app". The app scans through the `server/` worker
(`ProxyLLMService`) and carries no OpenAI key — BYOK is fully removed. Client auth is **Apple App
Attest**: the app signs each scan with an on-device Secure Enclave key and ships no static token.
**One worker** (`tridge-scan-api-test`) serves every build (Xcode-dev + TestFlight), with `store:true`
and the full production posture (per-device quotas, sanitized errors); it also accepts a static
bearer token solely for the local smoke harness. A dedicated production worker (separate URL +
isolated OpenAI key) is deferred — the code is env-driven so it drops in additively later
(`server/README.md` → "Adding a production worker later").

## Next action

The scan worker's production posture is implemented and tested in the repo; what remains is
owner-only provisioning (no code):

1. Create the `DEVICE_KV` namespace and paste its id into `server/wrangler.jsonc`
   (`wrangler kv namespace create DEVICE_KV`).
2. Set the worker secrets: `OPENAI_API_KEY` (budget-capped), `APPLE_TEAM_ID`, and `SCAN_API_TOKEN`.
   See `server/README.md` → Deploy.
3. Connect **Cloudflare Workers Builds** (dashboard → worker → Settings → Builds; root `server`,
   watch paths `server/**`).
4. Verify end-to-end: a **TestFlight** (Release) build scans against the worker on a real iPhone —
   App Attest can't run on the Simulator.

Still open beyond that: the browser-testable acceptance checklist on Appetize; the on-device
camera acceptance items via a TestFlight build; and, when wanted, the dedicated production
worker + isolated key.

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
  (Home grid + drag-to-consume + pull-down name search + the header filter button/sheet — Storage +
  Food Category filters via `Views/Home/FilterSheet.swift`, hidden on an empty fridge, search
  applying on top of the filters — scan flow + review sheet with per-row Food Category/Storage
  chips, item detail + art picker, settings). Saving — scanned or typed — merges into a matching
  active item by normalized name instead of duplicating it (`design/item-grouping-search.html`);
  manual add has quick-fill history chips above the name field and automatic art
  (remembered → inferred → tap-to-pick). Item detail and manual add render the same
  label-left / value-right field set (`Views/Shared/ItemFormRows.swift`).
- `Tridge.xcodeproj` — hand-written project (synchronized folder group) + shared scheme;
  see the decision log for why it's hand-authored.
- `.github/workflows/ci.yml` — Linux `swift test`; server typecheck + Vitest; release-lane syntax;
  macOS `swift test` + Debug simulator build,
  published as the `Tridge-simulator` artifact (Appetize.io's upload format) and, on pull
  requests, as a per-PR Appetize preview app whose link is commented on the PR (no-op without the
  `APPETIZE_API_TOKEN` secret). `.github/workflows/appetize-cleanup.yml` deletes a PR's preview
  app when the PR closes.
- `.github/workflows/testflight.yml` + `fastlane/` (`Fastfile`, `Appfile`) + `Gemfile` — the
  manual TestFlight release lane: `workflow_dispatch` builds a signed Release IPA (cloud-managed
  signing — no certs in the repo) and uploads it via fastlane's `upload_to_testflight`; the archive
  retries once when Apple's provisioning service transiently fails, before any upload begins. Signing
  hands the App Store Connect API key to `xcodebuild` itself via `-authenticationKey*` (gym does
  not forward it), so the workflow decodes the `.p8` to a file first; the key must have the
  **Admin** role because creating a distribution certificate is Admin-only. Needs the `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID` repo secrets (setup in `README.md` → "On your
  iPhone (TestFlight)"). Build number is the GitHub run number; `ITSAppUsesNonExemptEncryption=NO`
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
  as a fallback for the local smoke harness. `store:true` uniformly. One worker deploys today
  (`tridge-scan-api-test`, serving both Xcode-dev and TestFlight builds); the config is env-driven so
  a dedicated prod worker + isolated key is additive later. It is the single home of the receipt
  prompt + JSON schema. Vitest + tsc suite (`npm run typecheck && npm test`, incl. App Attest
  verification against known-good vectors); CI gates PRs; deploys go through Cloudflare Workers
  Builds (git integration), not CI. Setup/API: `server/README.md`.
- `wiki/` — this design-docs set.

## Not yet built

- Owner-only provisioning to bring the scan worker live: create the `DEVICE_KV` namespace, set the
  secrets (`OPENAI_API_KEY`, `APPLE_TEAM_ID`, `SCAN_API_TOKEN`), connect Cloudflare Workers Builds.
  See "Next action" and `server/README.md` → Deploy.
- A dedicated production worker + isolated budget-capped key (separate URL) — deferred; the code is
  ready for it (`server/README.md` → "Adding a production worker later").
- Verification of the spec's acceptance checklist on a test build: Appetize covers the
  simulator-safe items; the camera items and a live App Attest scan need a TestFlight build on a
  physical iPhone.
