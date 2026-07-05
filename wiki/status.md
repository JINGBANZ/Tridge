# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page.

## Current phase

v1 implemented end-to-end from the spec. Logic tests pass on Linux (`swift test`); the iOS build is
compiled only by CI's macOS job (`.github/workflows/ci.yml`), so the first CI run on the v1 PR is the
outstanding verification.

## Next action

Watch CI on the v1 PR: fix anything the macOS `xcodebuild` job surfaces, then merge. After that:
run through the spec's acceptance checklist on a simulator/device (needs a Mac or TestFlight via the
$99/yr Apple Developer account).

## Built

- `design/fridge-design.html` — the complete v2 design & build spec (mocks, tokens, screens,
  schema, LLM contract, acceptance criteria).
- `Package.swift` + `WhatsInMyFridge/Core/` — Linux-testable FridgeCore: LLM receipt-JSON parsing
  (`ReceiptParsing.swift`), the enforced response schema (`ReceiptSchema.swift`), urgency rules
  (`Urgency.swift`), date-label regex (`DateLabelParser.swift`), shared enums (`Types.swift`).
- `Tests/FridgeCoreTests/` — parsing (incl. fenced/prose-wrapped output), urgency thresholds,
  date-regex tests; all pass via `swift test`.
- `WhatsInMyFridge/` — the app: `App/` (entry, `AppTheme.swift` design tokens, preview seed),
  `Models/` (`FridgeItem.swift` SwiftData model, `Artwork.swift` artKey lookup), `Services/`
  (`LLMService.swift` OpenAI structured-outputs client, `ReceiptScanner.swift` VisionKit camera, `DateLabelScanner.swift`
  Vision OCR, `NotificationService.swift`, `KeychainStore.swift`, `Haptics.swift`), `Views/`
  (Home grid + drag-to-consume, scan flow + review sheet, item detail + art picker, settings).
- `WhatsInMyFridge.xcodeproj` — hand-written project (synchronized folder group) + shared scheme;
  see the decision log for why it's hand-authored.
- `.github/workflows/ci.yml` — Linux `swift test` + macOS `swift test` and simulator `xcodebuild`.
- `AGENTS.md` / `CLAUDE.md` — agent instructions; shared-rules block syncs from JINGBANZ/rules.
- `.github/workflows/sync-shared-rules.yml` — weekly shared-rules sync (stub → JINGBANZ/workflows).
- `.github/workflows/claude.yml`, `.github/workflows/claude-code-review.yml` — @claude mentions and
  automatic PR review (need the `CLAUDE_CODE_OAUTH_TOKEN` secret via `/install-github-app`).
- `wiki/` — this design-docs set.

## Not yet built

- On-device verification of the spec's acceptance checklist (no simulator on the Linux dev box).
- TestFlight distribution — needs the $99/yr Apple Developer account; after CI builds work.
