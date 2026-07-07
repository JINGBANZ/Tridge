# Decisions

> The project's decision log — *why* the system is the way it is. One entry per load-bearing,
> non-obvious choice. Unlike the rest of the wiki, this page is **append-mostly and historical**: it is
> the one place [`AGENTS.md`](./AGENTS.md) → Convention 3's "write in the present, delete the narration"
> rule does **not** apply, because the rejected alternative is exactly what you don't want to lose.
> No numbered files and no folder — a running list, newest last, each entry dated. When a decision is
> reversed, **supersede it in place** (add the `Superseded by` / `Supersedes` lines); never delete it.
> Keep it to genuinely load-bearing decisions (see [`AGENTS.md`](./AGENTS.md) → Convention 8); if a
> choice doesn't earn its entry, leave it out. The *how it works* lives in the core pages — link to it,
> don't restate it here.

### 2026-07-03 — LLM-first receipt scanning is the MVP core

- **Chose:** One multimodal LLM call (receipt photo → clean names, quantities, categories, emoji,
  shelf-life estimates as JSON) as the primary input path, shipped in v1.
- **Why:** Market research showed every incumbent (Fridgely, CozZo, Cooklist, NoWaste) covers the
  feature list on paper but is worst-reviewed exactly at receipt parsing, because they use legacy
  OCR + barcode-database pipelines. A vision LLM solves parsing and expiry-guessing in one step —
  it is the product's differentiator.
- **Rejected:** Manual-add-first MVP (defers the differentiator); OCR + barcode-lookup pipeline
  (the approach users already hate).

### 2026-07-04 — No backend; user-supplied Anthropic key in Keychain

- **Chose:** The app calls the Anthropic Messages API directly with a key the user pastes into
  Settings (stored in Keychain), behind an `LLMService` protocol.
- **Why:** Zero infrastructure for a personal-use v1; the protocol keeps a proxy swap trivial.
- **Rejected:** A key-holding proxy backend (Cloudflare Worker/Firebase) — right for a public App
  Store release, premature now.
- **Revisit if:** The app is distributed beyond the owner (TestFlight external testers or App Store).
- **Superseded by:** *2026-07-05 — OpenAI with enforced response schema* for the provider choice,
  and *2026-07-07 — Backend: Cloudflare Workers proxy* for the no-backend / key-in-Keychain parts;
  the `LLMService`-protocol part stands.

### 2026-07-04 — Items float frameless on the background; prebuilt art only; one button

- **Chose:** skylrk.com-style minimalism — item images render directly on a gradient background
  (no tile/card frames), art is a prebuilt set resolved via `artKey` (emoji in v1, swappable for
  sprites), and the home screen's only chrome is a single circular scan button (Settings behind a
  gear icon; no tab bar; stats screen cut to a counter line in Settings).
- **Why:** Owner's explicit direction after reviewing the v1 mock; keeps the image-first,
  game-inventory feel without UI chrome.
- **Rejected:** Frosted inventory tiles + tab bar (v1 mock); user-photo art (adds friction and a
  storage field for no v1 value).

### 2026-07-04 — Drag-to-drop-zones for consuming items

- **Chose:** Long-press-drag an item to "😋 Ate it" / "🗑️ Tossed" zones that appear only during
  the drag; tap opens a detail sheet with the same actions as fallback.
- **Why:** Swipe gestures don't work in a 4-column grid, and dragging matches the game-inventory
  metaphor. Tracking eaten vs tossed separately enables waste stats later.
- **Rejected:** Swipe-to-consume (original idea — grid-incompatible); tap-only menus (too slow for
  the most frequent action).

### 2026-07-04 — Root SwiftPM package + hand-written Xcode project

- **Chose:** A root `Package.swift` exposing `FridgeCore` (sources at `Tridge/Core/`, tests
  at `Tests/FridgeCoreTests/`) so the pure logic runs under `swift test` on the Linux dev box, and a
  hand-authored `Tridge.xcodeproj` (objectVersion 77, one synchronized folder group over
  `Tridge/`) that compiles the Core sources directly into the app target — no package
  product link, no `import FridgeCore` in app code.
- **Why:** Development happens on Linux with no Xcode; the project file must be writable and
  maintainable by hand. Synchronized folder groups mean new files join the target with zero pbxproj
  edits. Compiling Core into the app directly sidesteps Xcode's finicky handling of a local package
  rooted in the same directory as the project.
- **Rejected:** XcodeGen/Tuist (third-party toolchain dependency, unavailable on Linux); a classic
  per-file pbxproj (every added file needs a hand edit); linking `FridgeCore` as a local package
  product (self-referential package/project layout is fragile in Xcode).

### 2026-07-05 — OpenAI with enforced response schema

- **Chose:** `OpenAIService` (Chat Completions, `gpt-5-mini`) with strict Structured Outputs: the
  receipt reply is constrained server-side to the JSON Schema in
  `Tridge/Core/ReceiptSchema.swift`, which tests cross-check against the Swift DTOs.
  Supersedes the provider half of *2026-07-04 — No backend; user-supplied Anthropic key*.
- **Why:** Owner's direction. The previous contract only *requested* the JSON shape in the prompt;
  schema enforcement moves format guarantees from prompt discipline to the API, leaving client-side
  parsing as defense-in-depth (truncation/refusal) rather than the primary contract.
- **Rejected:** Staying on Anthropic (tool-use-based schema enforcement exists but the owner chose
  OpenAI); prompt-only JSON with client validation (what v1 shipped — schema violations surfaced
  only at parse time).
- **Superseded by:** *2026-07-05 — Responses API replaces Chat Completions* for the endpoint;
  the provider, model, and enforced-schema choices stand.

### 2026-07-05 — No lifetime eaten/tossed counters

- **Chose:** Drop the Settings-footer lifetime counters; v1 ships with no stats surface at all.
  `status`/`consumedDate` still record consumption, so waste stats remain buildable later.
- **Why:** Owner call — the counters were judged unnecessary.
- **Rejected:** Keeping the footer line (was itself the cut-down remnant of a rejected stats screen,
  see *2026-07-04 — Items float frameless…*).

### 2026-07-05 — Minimal LLM contract: curated item ids, no store/date/emoji

- **Chose:** The LLM returns per item only `id`, `name`, `receipt_text`, `quantity`,
  `shelf_life_days` — where `id` comes from the curated `ItemID` vocabulary
  (`Tridge/Core/Types.swift`), schema-enforced so out-of-vocabulary values are impossible.
  Art is resolved on-device from the id. No store name; `purchaseDate` is the scan day; storage
  comes from the Settings default. Unknown-item handling is tiered: specific id → generic bucket id
  (`fruit`, `vegetable`, …) → `unknown`, which the review sheet flags amber; the free-text `name`
  still describes the item either way. Ids added to the vocabulary later decode as `.unknown` on
  older builds (forward-compatible).
- **Why:** Owner's direction. LLM-generated emoji were uncontrollable (multi-glyph, non-food,
  unrenderable), whereas a closed id set guarantees every item maps to art we ship and makes a
  future custom sprite set a pure asset swap. Store/purchase-date/category/confidence carried no
  product value in v1; the generic buckets + `unknown` answer the "customers buy things outside the
  enum" concern without unbounded vocabulary growth.
- **Rejected:** Free-form LLM emoji (what v1 shipped — unvalidatable art); an ever-growing exhaustive
  food taxonomy (unmaintainable, and strict-mode enums have practical size limits); failing/dropping
  unrecognized items (silently losing food is worse than a generic icon).

### 2026-07-05 — Live receipt smoke tests with fuzzy fixture expectations

- **Chose:** A Linux-runnable integration test target (`Tests/ReceiptScanSmokeTests`): fixture
  receipt images + `expected.json` per fixture, sent through the real `OpenAIService` and matched
  with deliberately fuzzy assertions (name keywords, curated ids, count bounds, loose shelf-life
  bounds, forbidden keywords — never verbatim strings or absolute dates; expected↔parsed assignment
  is a maximum bipartite matching so overlapping keywords can't cause order-dependent false
  failures). Local-only: the key comes from the environment or a gitignored `.env` (`env.sample`
  template) and never enters the repo or CI, per the AGENTS.md security rule. The OpenAI client
  moved into the FridgeCore package target (with a completion-handler URLSession bridge) to make
  this possible without a Mac.
- **Why:** Validates the product's core differentiator — receipt → inventory quality — and catches
  model/prompt/schema regressions before any deploy, from a Linux box. Fuzzy matching because LLM
  wording is not run-to-run stable; exact-output snapshots would flake.
- **Rejected:** Mock-based tests only (can't catch model/prompt regressions); exact-output snapshot
  tests (flaky by construction); any CI execution, even manually triggered (an API-key secret in CI
  is disallowed outright by AGENTS.md → Setup).


### 2026-07-05 — Photo import + in-app diagnostics make Mac-less testing viable

- **Chose:** Two additions aimed at testing without local Xcode. (1) The scan button's tap falls
  back to a photo-library picker wherever the document camera is unavailable (Simulator,
  browser-hosted simulators), long-press offers the source menu, and debug builds bundle a
  synthetic sample receipt — the camera is an enhancement, not a requirement. (2) `AppLog`
  (`Tridge/Core/AppLog.swift`, OSLog-backed on Apple platforms, stdout on Linux) logs every
  scan/LLM/OCR failure point, and Settings → "Copy diagnostics" puts the session's logs on the
  clipboard for pasting into bug reports.
- **Why:** Owner testing happens in browser/cloud simulators and via sideloading, with feedback
  flowing back to a coding agent as text. Photo import is also a real product feature (e-receipt
  screenshots, photos taken earlier). Clipboard export needs no backend, no third-party SDK, and
  works identically in Appetize, the Simulator, and on-device.
- **Rejected:** Camera-only input (untestable off-device); a crash/telemetry SDK like Sentry
  (third-party dependency + backend, against v1 constraints); OS-level log capture as the only
  loop (Console.app/`simctl` need a Mac; testers won't run them).

### 2026-07-05 — Responses API replaces Chat Completions

- **Chose:** `OpenAIService` calls `POST /v1/responses` (`input`/`input_image`, `text.format`
  structured outputs, `max_output_tokens`, `reasoning.effort`) with **`store: false`** — receipts
  are personal data and Responses retains request content server-side by default. Supersedes the
  endpoint half of *2026-07-05 — OpenAI with enforced response schema*.
- **Why:** OpenAI's official guidance recommends Responses for all new projects (Chat Completions
  stays supported but new capabilities land on Responses first), and the migration cost was one
  file. `store: false` makes the privacy posture explicit rather than accidental. Verified live:
  all three smoke fixtures pass against the real endpoint.
- **Rejected:** Staying on Chat Completions (fine for a single-turn call, but leaves us off the
  recommended path for no benefit); leaving `store` at its default (silent server-side retention
  of receipt images).

### 2026-07-05 — Browser test builds via Appetize.io, not TestFlight

- **Chose:** CI's macOS job publishes a zipped Debug simulator `.app` per run (Appetize.io's
  upload format — it does not accept ipas), plus an auto-publish job that uploads it to Appetize
  on `main` pushes when the `APPETIZE_API_TOKEN` repo secret exists (a distribution credential
  the owner adds; unrelated to the OpenAI-key ban). Debug configuration on purpose: it keeps the
  bundled "Try sample receipt" flow in every test build.
- **Why:** No $99 Apple Developer Program, and development runs on a remote Linux VPS with no
  local Xcode. Appetize needs no Apple credentials at all and runs in a browser; camera-free
  testing is already first-class in the app (photo-library fallback + sample receipt), and
  Appetize can seed the simulator photo library, so the full scan → review → inventory flow is
  browser-testable. Free tier (100 min/month, one session) is enough for solo smoke tests.
- **Rejected:** TestFlight (needs the $99/yr program; still the right answer if the app ever goes
  beyond the owner); Waldo Sessions (comparable free simulator minutes but uncertain future under
  Tricentis); real-device clouds (BrowserStack/LambdaTest — camera image injection is attractive
  but paid; revisit if camera bugs need cloud reproduction). On-device distribution for the real
  camera/OCR (SideStore) is deliberately split into its own follow-up PR.

### 2026-07-06 — Simulator builds store the API key in UserDefaults, not the Keychain

- **Chose:** `KeychainStore` branches on `#if targetEnvironment(simulator)`: simulators persist
  the OpenAI key in `UserDefaults`; real devices keep the Keychain path, now with OSStatus
  failure logging on the new `AppLog.keychain` channel (status codes only, never key material).
- **Why:** Owner-reported bug on Appetize: pasting the key and tapping Done never stored it, so
  every scan bounced back to Settings. The CI simulator artifact is built with
  `CODE_SIGNING_ALLOWED=NO`; an app with no code signature has no entitlements, so every
  `SecItem*` call fails with `errSecMissingEntitlement` (-34018) — and the old code discarded
  the status, making the failure silent. The simulator keychain offers no real protection over
  its app container anyway, so UserDefaults is the honest equivalent there, and the security
  posture on real hardware (the only place a key is at actual risk) is unchanged.
- **Rejected:** Ad-hoc-signing the CI simulator build to restore entitlements (unverifiable
  from the Linux box that the entitlements Appetize's runtime accepts would result; app-level
  fix is deterministic); a runtime write-probe fallback (keychain-then-defaults) on all
  platforms (dead code on device, and a silent downgrade path is worse than an explicit
  compile-time branch); surfacing a save-error alert instead of fixing storage (keeps the
  simulator unusable).

### 2026-07-07 — Backend: Cloudflare Workers proxy (TypeScript) holds the OpenAI key

- **Chose:** Move the receipt-scan LLM call behind our own API: `server/`, a TypeScript worker
  on Cloudflare Workers, receives the receipt JPEG, calls the OpenAI Responses API with a
  server-held key (`wrangler secret put`), and returns the same `ParsedReceipt` JSON the app
  already parses. The app will swap in a proxy-backed `LLMService` conformance; all parsing/DTO
  logic stays in `FridgeCore`, and `Tests/FridgeCoreTests/ServerContractParityTests.swift` pins
  the duplicated prompt+schema to the app copies during the migration. Supersedes the
  no-backend / key-in-Keychain halves of *2026-07-04 — No backend*.
- **Why:** A consumer release can't ask users for an OpenAI key, and shipping our key in the
  binary is trivially extractable. Among hosts researched (July 2026), Workers uniquely
  combines: no wall-clock limit on HTTP requests (the 10–60 s OpenAI call is I/O wait, exempt
  from the 10 ms free-plan CPU cap), 100 MB request bodies, ~ms isolate cold starts, 100k free
  requests/day (~300× expected volume), and near-zero ops — the top criterion with no DevOps
  staff. Owner accepted TypeScript for the worker with clear app/server separation.
- **Rejected:** Cloud Run + Vapor (Swift end-to-end, 300 s default timeout, ~2M free req/mo —
  the runner-up, at the price of Docker images, slower cold starts, GCP administration); Vercel
  Functions (hard 4.5 MB body cap vs 1–5 MB photos); Lambda behind API Gateway (29 s integration
  timeout); Render free tier (15-min idle spin-down, ~1 min wake breaks the scan UX); Railway
  ($5/mo minimum, no sustained free tier); Fly.io (no free tier for new orgs).
- **Agent tooling:** Cloudflare's official Claude Code plugin (`cloudflare@cloudflare`, from the
  `cloudflare/skills` marketplace) is installed at the *user* level on the dev box per
  Cloudflare's agent-setup prompt — owner chose that over a checked-in `.claude/settings.json`.
  Fresh machine: `claude plugin marketplace add cloudflare/skills` +
  `claude plugin install cloudflare@cloudflare`.

### 2026-07-07 — Scan API ships test-first: bearer token + IP rate limit; store:true while testing

- **Chose:** The deployed worker is explicitly the *test* environment
  (`myfridge-scan-api-test`), protected in layers ordered rate-limit → auth → validation:
  a per-IP rate limit (10/min, Workers rate-limiting binding, checked first so tokens can't be
  brute-forced faster), a static bearer token (`SCAN_API_TOKEN` secret, timing-safe comparison),
  strict input validation (POST + `image/jpeg` + ≤8 MB only), sanitized error bodies (upstream
  OpenAI errors are logged, never echoed), and structured JSON logs with no image/key material.
  `STORE_RESPONSES=true` at OpenAI — owner's call so failed test scans are inspectable in the
  OpenAI dashboard — and the OpenAI key should be a dedicated test-project key with a budget
  cap. Deploys go through Cloudflare Workers Builds (the platform-recommended git
  integration; no Cloudflare token stored in GitHub), CI only gates PRs. Production later is
  a separate Wrangler environment/URL: `store:false`, App Attest assertions, per-device
  quotas.
- **Why:** A static token in a client binary is extractable in principle, so it can't be the
  production story — but for a pre-release test endpoint the realistic blast radius is our
  test-project OpenAI budget, which the rate limit plus budget cap bound. App Attest is the
  durable answer and slots in behind the same endpoint without contract changes.
- **Rejected:** No auth at all (URL obscurity is not a control; a scraped URL = free OpenAI
  proxy); shipping App Attest now (needs app-side work and an attestation-verification flow —
  wrong sequencing while the endpoint serves only the owner); Cloudflare WAF/zone rate rules
  (need a custom domain; the workers.dev binding-based limit covers the test env); mTLS/signed
  URLs (operational overkill for a single-client hobby API).

### 2026-07-07 — Product renamed to Tridge

- **Chose:** Rename the product from "MyFridge" / "What's In My Fridge" / "WhatsInMyFridge" to
  **Tridge** everywhere it surfaces: the Xcode target/scheme/product, the `Tridge/` source folder,
  the `TridgeApp` entry point, user-visible strings, docs, and CI artifact names. The bundle id
  becomes `com.tridge.app` and the Keychain service `com.tridge.credentials`; the OSLog subsystem
  becomes `com.tridge`. The scan-API worker is renamed `tridge-scan-api-test` (npm package
  `tridge-scan-api`). The GitHub repo is renamed `JINGBANZ/Tridge` (GitHub keeps redirects from the
  old path). The `FridgeCore` Swift module and the `ItemID`/DTO names are deliberately kept.
- **Why:** Owner decision on the product name. Doing it pre-release keeps the blast radius small:
  the bundle-id and Keychain-service change would orphan any stored key, which is acceptable with no
  users yet, and the worker is renamed before its first deploy so no live traffic is affected.
- **Rejected:** Keeping `WhatsInMyFridge` as an internal-only name (leaves a permanent mismatch
  between the shipped product and the codebase); deferring the bundle-id/Keychain-service change to
  avoid orphaning keys (no benefit pre-release, and a later change would then break real users).
