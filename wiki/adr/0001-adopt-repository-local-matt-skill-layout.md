# Adopt repository-local Matt skill paths

Tridge keeps the installed Matt Pocock skills upgradeable and overrides their generic repository
paths in root `AGENTS.md`: operational mappings live under `wiki/agents/`, the domain glossary lives
at `wiki/CONTEXT.md`, and new decisions use numbered ADRs under `wiki/adr/`. The existing
`wiki/decisions.md` remains a read-only legacy log instead of being split into a noisy migration.
