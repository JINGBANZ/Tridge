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
instructions are in `README.md` → "Trying the app". The backend migration is done for the scan
path: the app now scans through the deployed `server/` worker (`ProxyLLMService`) and carries no
OpenAI key — BYOK is fully removed. The worker still runs its test-env posture (static bearer
token, `STORE_RESPONSES=true`).

## Next action

Harden the scan API for production — stand up the **production** Wrangler environment
(`store:false`, Apple App Attest instead of the shared bearer token, per-device quotas, isolated
prod OpenAI key) — see the decision log, *2026-07-07* entries, and `design/backend-design.html` →
Migration plan. App Attest is now unblocked because TestFlight produces real signed builds (it
can't run on the simulator). Also connect the repo to Cloudflare Workers Builds (dashboard →
worker → Settings → Builds; root directory `server`, watch paths `server/**`) so `main` pushes
auto-deploy. Still open: the browser-testable acceptance checklist on Appetize; on-device
camera/OCR acceptance items via a TestFlight build.

## Built

- `design/fridge-design.html` — the complete v2 design & build spec (mocks, tokens, screens,
  schema, LLM contract, acceptance criteria).
- `Package.swift` + `Tridge/Core/` — Linux-testable FridgeCore: LLM receipt-JSON parsing
  (`ReceiptParsing.swift`), the curated `ItemID` vocabulary + shared enums (`Types.swift`), urgency
  rules (`Urgency.swift`), date-label regex (`DateLabelParser.swift`). The scan-API client
  (`../Services/ProxyLLMService.swift`) lives here too so the smoke test can drive it on Linux.
- `Tests/FridgeCoreTests/` — parsing (incl. fenced/prose-wrapped output), urgency
  thresholds, date-regex tests; all pass via `swift test`.
- `Tests/ReceiptScanSmokeTests/` — live regression harness: fixture receipt images +
  fuzzy `expected.json` inventories (see its `Fixtures/README.md`), sent through the deployed
  worker via `ProxyLLMService`; local-only — the bearer token comes from the environment or a
  gitignored `.env` (copy `env.sample`, `SCAN_API_TOKEN`; override the target with `BACKEND_URL`),
  skips without one, and is never run in CI. Ships three synthetic fixtures (clean, faded-thermal,
  crooked low-res photo); gitignored `Fixtures/private/` for personal receipts.
- `Tridge/` — the app: `App/` (entry, `AppTheme.swift` design tokens, preview seed),
  a single-tap add menu on the scan button (camera scan where a document camera exists ·
  photo-library import · "Type to add" manual entry via `Views/Home/ManualAddSheet.swift`, which
  needs no scan at all; debug builds add `Resources/SampleReceipt.jpg` and a "Seed the App" action
  that inserts the preset `PreviewData` inventory with no LLM call), `Core/AppLog.swift` +
  Settings → Copy diagnostics as the tester feedback loop,
  `Models/` (`FridgeItem.swift` SwiftData model, `Artwork.swift` artKey lookup), `Services/`
  (`LLMService.swift` protocol + errors, `ProxyLLMService.swift` scan-API client, `ScanAPIConfig.swift`
  worker URL + build-injected bearer token, `ReceiptScanner.swift` VisionKit camera, `DateLabelScanner.swift`
  Vision OCR, `NotificationService.swift`, `Haptics.swift`), `Views/`
  (Home grid + drag-to-consume, scan flow + review sheet, item detail + art picker, settings).
- `Tridge.xcodeproj` — hand-written project (synchronized folder group) + shared scheme;
  see the decision log for why it's hand-authored.
- `.github/workflows/ci.yml` — Linux `swift test`; server typecheck + Vitest;
  macOS `swift test` + Debug simulator build,
  published as the `Tridge-simulator` artifact (Appetize.io's upload format) and, on pull
  requests, as a per-PR Appetize preview app whose link is commented on the PR (no-op without the
  `APPETIZE_API_TOKEN` secret). `.github/workflows/appetize-cleanup.yml` deletes a PR's preview
  app when the PR closes.
- `.github/workflows/testflight.yml` + `fastlane/` (`Fastfile`, `Appfile`) + `Gemfile` — the
  manual TestFlight release lane: `workflow_dispatch` builds a signed Release IPA (cloud-managed
  signing — no certs in the repo) and uploads it via fastlane's `upload_to_testflight`. Signing
  hands the App Store Connect API key to `xcodebuild` itself via `-authenticationKey*` (gym does
  not forward it), so the workflow decodes the `.p8` to a file first; the key must have the
  **Admin** role because creating a distribution certificate is Admin-only. Needs the `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID` repo secrets (setup in `README.md` → "On your
  iPhone (TestFlight)"). Build number is the GitHub run number; `ITSAppUsesNonExemptEncryption=NO`
  is set so builds skip the export-compliance prompt.
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
  a worker secret; per-IP rate limit → bearer token (timing-safe) → strict input validation;
  test-env posture (`STORE_RESPONSES=true`, static token — see the decision log, *2026-07-07*).
  It is the single home of the receipt prompt + JSON schema now that the app calls it instead of
  OpenAI directly. Vitest + tsc suite (`npm run typecheck && npm test`); CI gates PRs with the
  server suite; deploys go through Cloudflare Workers Builds (git integration), not CI.
  Setup/API: `server/README.md`.
- `wiki/` — this design-docs set.

## Not yet built

- Production Wrangler environment for the scan API (`store:false`, App Attest replacing the shared
  bearer token, per-device quotas, isolated prod OpenAI key) — see the decision log, *2026-07-07*
  entries.
- Verification of the spec's acceptance checklist on a test build: Appetize covers the
  simulator-safe items; the camera/OCR items need a TestFlight build on a physical iPhone.
