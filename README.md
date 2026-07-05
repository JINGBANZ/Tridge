# MyFridge — What's In My Fridge

Scan your grocery receipt → an LLM turns it into a live fridge inventory with
expiration dates → items float on a minimal home screen, turning amber, then red,
as they near expiry. Drag an item to "😋 Ate it" or "🗑️ Tossed" when it leaves
the fridge.

**Status: v1 implemented.** The complete design & build spec (with screen mocks)
lives at [`design/fridge-design.html`](design/fridge-design.html) — open it in a
browser. Agents: start with [`AGENTS.md`](AGENTS.md), then [`wiki/index.md`](wiki/index.md).

## Building & testing

- Logic tests (any platform, incl. Linux): `swift test`
- Live receipt-scan smoke tests (real OpenAI call against fixture receipts):
  `OPENAI_API_KEY=sk-… swift test --filter ReceiptScanSmokeTests` — see
  [`Tests/ReceiptScanSmokeTests/Fixtures/README.md`](Tests/ReceiptScanSmokeTests/Fixtures/README.md)
  for how to add your own receipt images + expected inventory. Also runnable
  on demand in CI (Actions → "Receipt smoke test", needs the `OPENAI_API_KEY` secret).
- iOS app (macOS + Xcode 16): open `WhatsInMyFridge.xcodeproj`, or
  `xcodebuild -scheme WhatsInMyFridge -destination 'generic/platform=iOS Simulator' build`
- Runtime setup: paste your OpenAI API key in Settings (gear icon) — it is
  stored only in the device Keychain.

## Manual testing on a simulator or device

Requires a Mac with Xcode 16+ (the iOS SDK doesn't exist on Linux):

1. Clone the repo, open `WhatsInMyFridge.xcodeproj`.
2. **Simulator:** pick any iPhone simulator and press Run. No Apple account
   needed. The document camera doesn't exist on the simulator, but the scan
   button falls back to the photo-library picker there (drag receipt images
   into the simulator's Photos app first), and debug builds offer "Try sample
   receipt" via long-press — so the whole scan → review → inventory flow is
   testable without hardware. Only the real camera and date-label OCR capture
   need a device.
3. **Your iPhone (free Apple ID):** in the target's Signing & Capabilities set
   your personal team and a unique bundle id, enable Developer Mode on the phone
   (Settings → Privacy & Security), plug it in and press Run. Free-account
   signatures expire after 7 days — re-run from Xcode to refresh.
4. **No Mac at hand:** join the Apple Developer Program ($99/yr) and distribute
   CI builds via TestFlight (see the spec's "Development environment" section).

## Reporting issues from a test build

The feedback loop is built in:

1. Reproduce the problem in the app.
2. Settings (gear icon) → **Copy diagnostics** — puts this session's app logs
   (scan sizes, LLM HTTP errors, parse failures, OCR results; never your API
   key) on the clipboard.
3. Paste into the bug report / hand it to the coding agent.

Logs cover the current launch only, so copy right after reproducing. For hard
crashes: on-device crash logs live under iOS Settings → Privacy & Security →
Analytics & Improvements → Analytics Data (share the newest
`WhatsInMyFridge-…​.ips` file).

## v1

- LLM receipt scanning (VisionKit capture or photo import → vision LLM call → review sheet)
- Expiry tracking with local notifications (T−2 days and expiry day)
- Game-inventory-style home grid, sorted soonest-expiring first
- Drag-to-consume, on-device OCR for printed "best by" dates
- iOS 17+, SwiftUI + SwiftData, no third-party packages, no backend

## Later

Grocery list generation · recipe suggestions · CloudKit sync / household sharing
