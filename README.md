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
- Live receipt-scan smoke tests (real OpenAI call against fixture receipts,
  local-only — the key is never in the repo or CI): copy `env.sample` to `.env`,
  fill in your key, then `swift test --filter ReceiptScanSmokeTests`. See
  [`Tests/ReceiptScanSmokeTests/Fixtures/README.md`](Tests/ReceiptScanSmokeTests/Fixtures/README.md)
  for how to add your own receipt images + expected inventory.
- iOS app (macOS + Xcode 16): open `WhatsInMyFridge.xcodeproj`, or
  `xcodebuild -scheme WhatsInMyFridge -destination 'generic/platform=iOS Simulator' build`
- Runtime setup: paste your OpenAI API key in Settings (gear icon) — it is
  stored only in the device Keychain.

## Installing a test build (no Mac needed)

Every CI run publishes two build artifacts (GitHub → **Actions** → latest run →
**Artifacts**). Both are Debug builds, so the long-press → "Try sample receipt"
flow is included.

- `WhatsInMyFridge-simulator` — zipped simulator app, for running in the
  browser on [Appetize.io](https://appetize.io)
- `WhatsInMyFridge-ipa` — **unsigned** ipa, for sideloading onto an iPhone with
  [SideStore](https://sidestore.io) (which re-signs it with your own Apple ID)

### Browser simulator via Appetize.io

No Apple account, no hardware. The camera doesn't exist here: the scan button
falls back to the photo-library picker, and "Try sample receipt" covers the
full scan → review → inventory flow.

1. Download the `WhatsInMyFridge-simulator` artifact and unzip it once (GitHub
   wraps artifacts in an outer zip) to get `WhatsInMyFridge-sim.zip`.
2. Sign up free at [appetize.io](https://appetize.io), **Upload** →
   `WhatsInMyFridge-sim.zip` (the zipped `.app`, not the ipa), platform iOS.
3. Open the generated app page and press play. Free tier: 100 streaming
   minutes/month, one session at a time, ~2-minute inactivity timeout —
   enough for solo smoke tests.

If the `APPETIZE_API_TOKEN` repo secret is configured, CI uploads each push
to Appetize automatically — then you just reopen your existing Appetize link.

### Your iPhone via SideStore (free Apple ID, no Mac)

The only path where the real receipt camera and date-label OCR work.
Free-Apple-ID limits apply: signatures last 7 days (refresh happens on-device
in SideStore — no computer needed after setup) and max 3 sideloaded apps.

One-time setup (see [docs.sidestore.io](https://docs.sidestore.io) for the
authoritative, current steps — iOS point releases occasionally break
sideloading until SideStore ships a fix). This needs a computer with the
iPhone on USB — any local macOS/Windows/Linux machine works (a remote
VPS does not; no USB):

1. Download **iloader** ([iloader.app](https://iloader.app), SideStore's
   official installer — macOS/Windows/Linux builds), connect the iPhone over
   USB, sign in with your Apple ID. It generates the device pairing file and
   installs SideStore, signed with your free Apple ID. After this, installs
   and refreshes happen entirely on the phone — no computer involved again.
2. On the phone, install **LocalDevVPN** from the App Store and toggle it on
   whenever installing/refreshing — this loopback VPN is what lets SideStore
   re-sign apps on-device without a computer.

Per build:

1. Download the `WhatsInMyFridge-ipa` artifact, unzip the outer artifact zip
   to get `WhatsInMyFridge.ipa`, and get it onto the phone (any file transfer:
   cloud drive, local web server, …).
2. In SideStore: **+** → pick the ipa. SideStore signs it with your Apple ID
   and installs it. Re-tap **Refresh** any time before the 7-day signature
   expires.

Optional accelerator: [**LiveContainer**](https://github.com/LiveContainer/LiveContainer)
(installable through SideStore, or pick iloader's SideStore + LiveContainer
combo during setup) runs apps as guests inside its own container. Importing a
new ipa then needs **no re-signing round-trip at all** and doesn't count
against the free-Apple-ID 3-app limit — the fastest install-per-build loop.
Guest caveats: no remote push (the app only uses local notifications) and
entitlements aren't applied.

### With a Mac (Xcode 16+)

1. Clone the repo, open `WhatsInMyFridge.xcodeproj`.
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
`WhatsInMyFridge-…​.ips` file).

## v1

- LLM receipt scanning (VisionKit capture or photo import → vision LLM call → review sheet)
- Expiry tracking with local notifications (T−2 days and expiry day)
- Game-inventory-style home grid, sorted soonest-expiring first
- Drag-to-consume, on-device OCR for printed "best by" dates
- iOS 17+, SwiftUI + SwiftData, no third-party packages, no backend

## Later

Grocery list generation · recipe suggestions · CloudKit sync / household sharing
