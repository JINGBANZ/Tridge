# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repository root.
- **`CONTEXT-MAP.md`** at the root if it exists; read each context relevant to the topic.
- **`docs/adr/`**; read ADRs affecting the area being changed.

If these files don't exist, proceed silently. The domain-modeling workflows create them lazily when terminology or decisions are resolved.

## File structure

This is a single-context repository:

```
/
├── CONTEXT.md
├── docs/adr/
├── Tridge/
├── Tests/
├── server/
└── design/
```

## Use the glossary's vocabulary

When output names a domain concept, use the term defined in `CONTEXT.md`. Don’t drift to synonyms the glossary explicitly avoids.

If a needed concept isn’t present, reconsider whether the term belongs to the project or note the genuine gap for domain modeling.

## Flag ADR conflicts

If output contradicts an existing ADR, surface the conflict explicitly rather than silently overriding it.
