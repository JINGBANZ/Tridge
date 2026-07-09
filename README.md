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

## Trying the app

### On your iPhone (TestFlight) — real device, real camera

This is the path for actual on-device use, including the receipt camera and
date-label OCR. CI does the macOS build; you never need a Mac. It requires a
paid **Apple Developer Program** membership ($99/yr).

**One-time setup:**

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/).
2. In [App Store Connect](https://appstoreconnect.apple.com) → **Apps** → **+** →
   **New App**, create an app with bundle id `com.tridge.app`. (If that id is
   already taken, pick another and change `PRODUCT_BUNDLE_IDENTIFIER` in
   `Tridge.xcodeproj` and `app_identifier` in `fastlane/Appfile` to match.)
3. Create an **App Store Connect API key**: App Store Connect → **Users and
   Access** → **Integrations** → **App Store Connect API** → **+**, role **App
   Manager**. Note the **Issuer ID** and **Key ID**, and download the
   `AuthKey_XXXX.p8` (downloadable only once).
4. Add four **repository secrets** (GitHub → repo **Settings** → **Secrets and
   variables** → **Actions**):
   - `ASC_KEY_ID` — the API Key ID
   - `ASC_ISSUER_ID` — the Issuer ID
   - `ASC_KEY_P8` — the base64 of the `.p8` file: `base64 -i AuthKey_XXXX.p8`
   - `APPLE_TEAM_ID` — your 10-character Team ID (developer.apple.com → **Membership**)

   (Live scanning also needs the existing `SCAN_API_TOKEN` secret; without it the
   build still ships but scans report "Scanning isn't set up".)

**Each release:** GitHub → **Actions** → **TestFlight** → **Run workflow**. It
builds a signed Release IPA (signing is cloud-managed via the API key — no certs
in the repo) and uploads it. A few minutes later the build appears in TestFlight;
install the **TestFlight** app on your iPhone and accept the invite to run it.

### Browser preview (Appetize) — quick UI check, no camera

For a zero-setup look at the UI with no Apple account or hardware, every CI run
publishes the `Tridge-simulator` artifact (GitHub → **Actions** → latest run →
**Artifacts**): a zipped Debug simulator app for [Appetize.io](https://appetize.io).
There's no camera here — the scan menu offers "Choose from library" and "Try
sample receipt" instead, and "Seed the App" fills the fridge with no scan at all.

1. Download the `Tridge-simulator` artifact and unzip it once (GitHub wraps
   artifacts in an outer zip) to get `Tridge-sim.zip`.
2. Sign up free at [appetize.io](https://appetize.io), **Upload** →
   `Tridge-sim.zip` (the zipped `.app`, not an ipa), platform iOS, and press play.

If the `APPETIZE_API_TOKEN` repo secret is set, **pull requests** get their own
Appetize preview automatically: CI comments the link on the PR and updates it on
every push (the preview app is deleted when the PR closes) — handy for reviewing
UI changes before merge. Scanning works here too, since the worker bearer token
is compiled into the build from `SCAN_API_TOKEN`.

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
