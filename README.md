# Tridge

Scan your grocery receipt → an LLM turns it into a live fridge inventory with
expiration dates → items float on a minimal home screen, turning amber, then red,
as they near expiry. Drag an item to "😋 Ate it" or "🗑️ Tossed" when it leaves
the fridge.

**Status: v1 implemented.** The complete design & build spec (with screen mocks)
lives at [`design/fridge-design.html`](design/fridge-design.html) — open it in a
browser. Agents: start with [`AGENTS.md`](AGENTS.md), then [`wiki/index.md`](wiki/index.md).

## Building & testing

- Logic tests (any platform, incl. Linux): `swift test`
- Live receipt-scan smoke tests (fixture receipts through the deployed scan-API
  worker, local-only — no secret in the repo or CI): copy `env.sample` to `.env`,
  fill in `SCAN_API_TOKEN`, then `swift test --filter ReceiptScanSmokeTests`. See
  [`Tests/ReceiptScanSmokeTests/Fixtures/README.md`](Tests/ReceiptScanSmokeTests/Fixtures/README.md)
  for how to add your own receipt images + expected inventory.
- iOS app (macOS + Xcode 16): drop the worker `SCAN_API_TOKEN` into
  `Tridge/Resources/ScanAPIToken.txt` (gitignored — `printf '%s' "$TOKEN" > Tridge/Resources/ScanAPIToken.txt`),
  then open `Tridge.xcodeproj`, or
  `xcodebuild -scheme Tridge -destination 'generic/platform=iOS Simulator' build`
- Runtime: no user setup — scanning goes through the scan-API worker, which holds the
  OpenAI key. The app carries only the worker bearer token, bundled from
  `Tridge/Resources/ScanAPIToken.txt` at build time (a build without it reports
  "Scanning isn't set up" instead of scanning).

## Installing a test build (no Mac needed)

Every CI run publishes the `Tridge-simulator` build artifact (GitHub →
**Actions** → latest run → **Artifacts**): a zipped simulator app for running
in the browser on [Appetize.io](https://appetize.io). It's a Debug build, so
the scan-menu extras ("Try sample receipt", "Seed the App") are included.

### Browser simulator via Appetize.io

No Apple account, no hardware. The camera doesn't exist here: the scan
button's menu offers "Choose from library" instead, and "Try sample receipt"
covers the full scan → review → inventory flow. To just see the app working
with zero setup, tap the scan button → **Seed the App**: it fills the fridge
with preset items across every urgency tier — no scan, no LLM call.

1. Download the `Tridge-simulator` artifact and unzip it once (GitHub
   wraps artifacts in an outer zip) to get `Tridge-sim.zip`.
2. Sign up free at [appetize.io](https://appetize.io), **Upload** →
   `Tridge-sim.zip` (the zipped `.app`, not the ipa), platform iOS.
3. Open the generated app page and press play. Free tier: 100 streaming
   minutes/month, one session at a time, ~2-minute inactivity timeout —
   enough for solo smoke tests.

If the `APPETIZE_API_TOKEN` repo secret is configured, CI uploads each push
to Appetize automatically — then you just reopen your existing Appetize link.
Pull requests get their own separate preview app: CI comments the link on the
PR and updates it on every push, so changes are viewable before they reach
`main` (the preview app is deleted when the PR closes).

Scanning works with no per-session setup: the app authenticates to the worker
with a bearer token compiled into the build, so "Try sample receipt", photo
import, "Type to add", and "Seed the App" all work on a freshly wiped device —
provided the published build was compiled with a `SCAN_API_TOKEN` (CI injects it
from the repo secret; otherwise scans report "Scanning isn't set up").

Real receipt camera and date-label OCR need a physical iPhone — that
distribution path (SideStore sideloading) is planned separately.

### With a Mac (Xcode 16+)

1. Clone the repo, open `Tridge.xcodeproj`.
2. **Simulator:** pick any iPhone simulator and press Run. No Apple account
   needed. Same camera fallbacks as Appetize (drag receipt images into the
   simulator's Photos app to test the picker path).
3. **Your iPhone (free Apple ID):** in the target's Signing & Capabilities set
   your personal team and a unique bundle id, enable Developer Mode on the phone
   (Settings → Privacy & Security), plug it in and press Run. Free-account
   signatures expire after 7 days — re-run from Xcode to refresh.

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
`Tridge-…​.ips` file).

## v1

- LLM receipt scanning (VisionKit capture or photo import → vision LLM call → review sheet)
- Expiry tracking with local notifications (T−2 days and expiry day)
- Game-inventory-style home grid, sorted soonest-expiring first
- Drag-to-consume, on-device OCR for printed "best by" dates
- iOS 17+, SwiftUI + SwiftData, no third-party packages, no backend

## Later

Grocery list generation · recipe suggestions · CloudKit sync / household sharing
