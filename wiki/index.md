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

## Decisions

- [decisions.md](./decisions.md) — the decision log: what was chosen and why, with the rejected
  alternative. One page, no ADR folder by design; see [`AGENTS.md`](./AGENTS.md) → Convention 8.

## Meta

- [AGENTS.md](./AGENTS.md) — conventions for maintaining this wiki. Read before editing any wiki file.
