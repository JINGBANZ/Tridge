# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page.

## Current phase

Design complete; no application code yet. The repo carries the finished build spec and the shared
agent-rules scaffolding, ready for the v1 implementation.

## Next action

Build the app end-to-end from `design/fridge-design.html`: follow the build order in the spec's
final callout (Models + Artwork lookup → AppTheme → Home grid with sample data → drag-to-consume →
LLM service + scan flow → review sheet → detail + notifications → OCR date scan → settings → tests)
and stop only when every item in the spec's acceptance-criteria checklist passes.

## Built

- `design/fridge-design.html` — the complete v2 design & build spec (mocks, tokens, screens,
  schema, LLM contract, acceptance criteria).
- `AGENTS.md` / `CLAUDE.md` — agent instructions; shared-rules block syncs from JINGBANZ/rules.
- `.github/workflows/sync-shared-rules.yml` — weekly shared-rules sync (stub → JINGBANZ/workflows).
- `.github/workflows/claude.yml`, `.github/workflows/claude-code-review.yml` — @claude mentions and
  automatic PR review (need the `CLAUDE_CODE_OAUTH_TOKEN` secret via `/install-github-app`).
- `wiki/` — this design-docs set.

## Not yet built

- `WhatsInMyFridge/` Xcode project — the entire v1 app per the spec.
- CI build workflow (macOS runner: xcodebuild + tests) — add when the Xcode project exists.
- TestFlight distribution — needs the $99/yr Apple Developer account; after CI builds work.
