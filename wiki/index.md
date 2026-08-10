# Wiki index

> Single source of truth for "what pages exist in this wiki" — the navigation layer any fresh reader
> (human or agent) starts from. Keep it in sync whenever you add, rename, or remove a page.
> Tridge is an iOS app that turns a scanned grocery receipt into a live fridge inventory with
> LLM-guessed expiration dates.

## Start here

- [status.md](./status.md) — what is built right now, with file pointers, and what to do next. **Read
  this first** if you're picking the project up mid-stream.

## Core pages

- [../design/fridge-design.html](../design/fridge-design.html) — **the complete design & build
  spec**: screen mocks, design tokens, all screens/interactions, the current Core Data sharing
  schema summary, the OpenAI API contract with the verbatim receipt prompt, project layout,
  acceptance criteria, and build order. Open in a browser for visuals; its sharing-release details
  delegate explicitly to [household-sharing.md](./household-sharing.md).
- [../design/backend-design.html](../design/backend-design.html) — the **backend design doc**
  for the receipt-scan API (`server/`, Cloudflare Worker): architecture, request-protection
  layers, API contract, test-vs-production posture, migration plan, and the hosting research
  that picked Workers. Deployment state lives in [status.md](./status.md); the *why* lives in
  [decisions.md](./decisions.md) → *2026-07-07* entries.
- [../design/item-grouping-search.html](../design/item-grouping-search.html) — the **item
  grouping & search design doc**: merge-at-confirm for rescanned/re-bought items (issue #26),
  the name-key identity model, name search, manual-add quick-fill chips, and tiered automatic
  art — with animated flow mocks and the competitor/platform research. The *why* lives in
  [decisions.md](./decisions.md) → *2026-07-11* entry.
- [../design/household-sharing-overview.html](../design/household-sharing-overview.html) — a
  **plain-language visual map** of the proposed sharing architecture: the system graph, new module
  responsibilities, everyday examples, implementation path, and any focused review corrections
  still required. The normative contract remains [household-sharing.md](./household-sharing.md).
- [household-sharing.md](./household-sharing.md) — the reviewed **household sharing architecture**:
  exact Apple capabilities/schema/store routing, account isolation, invitation and lifecycle UI,
  repository commands, multi-writer stock events, lossless exact-name item convergence, the reviewed
  dependency boundary, notification reconciliation, privacy/export/deletion, the automatic
  no-uninstall reset, implementation checkpoints, and owner-only handoff. Implementation state
  lives in [status.md](./status.md); the *why* lives in
  [decisions.md](./decisions.md) → *2026-08-06*, *2026-08-08*, and *2026-08-09* entries.

## Decisions

- [decisions.md](./decisions.md) — the decision log: what was chosen and why, with the rejected
  alternative. One page, no ADR folder by design; see [`AGENTS.md`](./AGENTS.md) → Convention 8.

## Meta

- [AGENTS.md](./AGENTS.md) — conventions for maintaining this wiki. Read before editing any wiki file.
