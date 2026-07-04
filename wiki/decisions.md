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
