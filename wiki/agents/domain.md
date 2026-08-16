# Domain docs

Repository-specific path overrides for Matt Pocock's domain-aware engineering skills.

## Path mapping

| Generic skill path | Tridge path |
| --- | --- |
| `CONTEXT.md` | `wiki/CONTEXT.md` |
| `CONTEXT-MAP.md` | `wiki/CONTEXT-MAP.md` if Tridge ever becomes multi-context |
| `docs/adr/` | `wiki/adr/` |

These mappings override the generic locations named by an installed skill. `wiki/decisions.md` is
the historical decision log; read it for earlier rationale, but record new decisions as numbered
ADRs under `wiki/adr/`.

## Before exploring

1. Read `wiki/CONTEXT.md` if it exists and use its canonical vocabulary.
2. Start at `wiki/index.md`, then read `wiki/status.md` and the core pages relevant to the task.
3. Read applicable ADRs under `wiki/adr/` and search `wiki/decisions.md` for older decisions.
4. Treat `design/fridge-design.html` as the complete build spec when implementation is involved.

If the glossary or ADR directory does not exist, proceed silently. Create either lazily only when a
term or qualifying decision is actually resolved.

## Maintain the domain model

- Keep `wiki/CONTEXT.md` a concise glossary of project-specific terms, definitions, and explicitly
  avoided synonyms. Do not put implementation details, status, plans, or architecture decisions in
  it.
- Add a term inline when discussion resolves it; do not batch speculative vocabulary.
- Record a new ADR only when the choice is hard to reverse, surprising without context, and the
  result of a real trade-off. Use `wiki/adr/NNNN-slug.md` with the next sequential number.
- Surface conflicts with the glossary, an ADR, or the legacy decision log instead of silently
  overriding them.

Read `wiki/AGENTS.md` before editing anything under `wiki/`, and update `wiki/index.md` whenever a
glossary or ADR page is added, renamed, or removed.
