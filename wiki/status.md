# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page.

## Current phase

v1 merged and CI green (Linux `swift test` + macOS build). CI now also publishes installable test
builds on every run: a zipped Debug simulator app (Appetize.io browser testing) and an unsigned
Debug ipa (SideStore sideloading onto the owner's iPhone with a free Apple ID). Install
instructions are in `README.md` → "Installing a test build". The `APPETIZE_API_TOKEN` repo secret
is set, so the auto-publish job uploads each `main` push to Appetize.

## Next action

After the first `main` push triggers the Appetize upload: take the `publicKey` from the job log
and set it as the `APPETIZE_APP_PUBLICKEY` repo variable so later pushes update one stable app.
Owner-side device setup: one-time SideStore pairing of the iPhone over USB from a local computer
(the owner's MacBook — the dev VPS has no USB), per `README.md`. Then run the spec's acceptance
checklist on the test builds — the SideStore install covers the camera/OCR items.

## Built

- `design/fridge-design.html` — the complete v2 design & build spec (mocks, tokens, screens,
  schema, LLM contract, acceptance criteria).
- `Package.swift` + `WhatsInMyFridge/Core/` — Linux-testable FridgeCore: LLM receipt-JSON parsing
  (`ReceiptParsing.swift`), the enforced response schema (`ReceiptSchema.swift`), the curated
  `ItemID` vocabulary + shared enums (`Types.swift`), urgency rules (`Urgency.swift`), date-label
  regex (`DateLabelParser.swift`).
- `Tests/FridgeCoreTests/` — parsing (incl. fenced/prose-wrapped output), schema-contract, urgency
  thresholds, date-regex tests; all pass via `swift test`.
- `Tests/ReceiptScanSmokeTests/` — live LLM regression harness: fixture receipt images +
  fuzzy `expected.json` inventories (see its `Fixtures/README.md`); local-only — key comes
  from the environment or a gitignored `.env` (copy `env.sample`), skips without one, and is
  never run in CI. Ships three synthetic fixtures (clean, faded-thermal, crooked low-res
  photo); gitignored `Fixtures/private/` for personal receipts.
- `WhatsInMyFridge/` — the app: `App/` (entry, `AppTheme.swift` design tokens, preview seed),
  scan input via document camera or photo-library import (camera-free platforms fall back
  automatically; debug builds bundle `Resources/SampleReceipt.jpg`), `Core/AppLog.swift` +
  Settings → Copy diagnostics as the tester feedback loop,
  `Models/` (`FridgeItem.swift` SwiftData model, `Artwork.swift` artKey lookup), `Services/`
  (`LLMService.swift` OpenAI structured-outputs client, `ReceiptScanner.swift` VisionKit camera, `DateLabelScanner.swift`
  Vision OCR, `NotificationService.swift`, `KeychainStore.swift`, `Haptics.swift`), `Views/`
  (Home grid + drag-to-consume, scan flow + review sheet, item detail + art picker, settings).
- `WhatsInMyFridge.xcodeproj` — hand-written project (synchronized folder group) + shared scheme;
  see the decision log for why it's hand-authored.
- `.github/workflows/ci.yml` — Linux `swift test`; macOS `swift test` + Debug builds for simulator
  and device, published as artifacts (`WhatsInMyFridge-simulator` zip for Appetize.io,
  `WhatsInMyFridge-ipa` unsigned ipa for SideStore); Appetize auto-publish job on `main` pushes
  (no-ops without the `APPETIZE_API_TOKEN` secret).
- `AGENTS.md` / `CLAUDE.md` — agent instructions; shared-rules block syncs from JINGBANZ/rules.
- `.github/workflows/sync-shared-rules.yml` — weekly shared-rules sync (stub → JINGBANZ/workflows).
- `.github/workflows/claude.yml`, `.github/workflows/claude-code-review.yml` — @claude mentions and
  automatic PR review (need the `CLAUDE_CODE_OAUTH_TOKEN` secret via `/install-github-app`).
- `wiki/` — this design-docs set.

## Not yet built

- Verification of the spec's acceptance checklist on a test build (Appetize for the simulator-safe
  items, SideStore install for camera/OCR items).
- Owner-side SideStore pairing (one-time, local computer) — documented in `README.md`, cannot be
  done from CI.
