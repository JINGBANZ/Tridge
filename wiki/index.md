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
  spec**: screen mocks, design tokens, all screens/interactions, SwiftData schema, the OpenAI
  API contract with the verbatim receipt prompt, project layout, acceptance criteria, and build
  order. Open in a browser for visuals; the text and mock CSS are the normative spec.
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
- [household-sharing.md](./household-sharing.md) — the approved **household sharing architecture**:
  CloudKit ownership and invitations, private/shared persistence, the repository boundary,
  multi-writer convergence, notification reconciliation, and the automatic no-uninstall reset.
  Implementation state lives in [status.md](./status.md); the *why* lives in
  [decisions.md](./decisions.md) → *2026-08-06* entries.

## Decisions

- [decisions.md](./decisions.md) — the decision log: what was chosen and why, with the rejected
  alternative. One page, no ADR folder by design; see [`AGENTS.md`](./AGENTS.md) → Convention 8.

## Meta

- [AGENTS.md](./AGENTS.md) — conventions for maintaining this wiki. Read before editing any wiki file.
