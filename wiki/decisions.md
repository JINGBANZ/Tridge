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
- **Superseded by:** *2026-07-05 — OpenAI with enforced response schema* for the provider choice;
  the no-backend / key-in-Keychain / `LLMService`-protocol parts stand.

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

- **Chose:** A root `Package.swift` exposing `FridgeCore` (sources at `WhatsInMyFridge/Core/`, tests
  at `Tests/FridgeCoreTests/`) so the pure logic runs under `swift test` on the Linux dev box, and a
  hand-authored `WhatsInMyFridge.xcodeproj` (objectVersion 77, one synchronized folder group over
  `WhatsInMyFridge/`) that compiles the Core sources directly into the app target — no package
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
  `WhatsInMyFridge/Core/ReceiptSchema.swift`, which tests cross-check against the Swift DTOs.
  Supersedes the provider half of *2026-07-04 — No backend; user-supplied Anthropic key*.
- **Why:** Owner's direction. The previous contract only *requested* the JSON shape in the prompt;
  schema enforcement moves format guarantees from prompt discipline to the API, leaving client-side
  parsing as defense-in-depth (truncation/refusal) rather than the primary contract.
- **Rejected:** Staying on Anthropic (tool-use-based schema enforcement exists but the owner chose
  OpenAI); prompt-only JSON with client validation (what v1 shipped — schema violations surfaced
  only at parse time).

### 2026-07-05 — No lifetime eaten/tossed counters

- **Chose:** Drop the Settings-footer lifetime counters; v1 ships with no stats surface at all.
  `status`/`consumedDate` still record consumption, so waste stats remain buildable later.
- **Why:** Owner call — the counters were judged unnecessary.
- **Rejected:** Keeping the footer line (was itself the cut-down remnant of a rejected stats screen,
  see *2026-07-04 — Items float frameless…*).

### 2026-07-05 — Minimal LLM contract: curated item ids, no store/date/emoji

- **Chose:** The LLM returns per item only `id`, `name`, `receipt_text`, `quantity`,
  `shelf_life_days` — where `id` comes from the curated `ItemID` vocabulary
  (`WhatsInMyFridge/Core/Types.swift`), schema-enforced so out-of-vocabulary values are impossible.
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

