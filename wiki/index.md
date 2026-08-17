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
  responsibilities, everyday examples, implementation path, and reviewed safety boundaries. The
  normative contract remains [household-sharing.md](./household-sharing.md).
- [household-sharing.md](./household-sharing.md) — the reviewed **household sharing architecture**:
  exact Apple capabilities/schema/store routing, account isolation, invitation and lifecycle UI,
  repository commands, multi-writer stock events, lossless exact-name item convergence, the reviewed
  dependency boundary, notification reconciliation, privacy/export/deletion, the automatic
  no-uninstall active-inventory migration, implementation checkpoints, and authorized release
  handoff. Implementation state lives in [status.md](./status.md); the *why* lives in
  [decisions.md](./decisions.md) → *2026-08-06*, *2026-08-08*, and *2026-08-09* entries.

## Decisions

- [CONTEXT.md](./CONTEXT.md) — canonical language for households, inventory, roles, and calendar-day
  semantics.
- [adr/0001-adopt-repository-local-matt-skill-layout.md](./adr/0001-adopt-repository-local-matt-skill-layout.md)
  — why Matt's generic skill paths are mapped into Tridge's wiki.
- [adr/0002-migrate-legacy-inventory-into-household-sharing.md](./adr/0002-migrate-legacy-inventory-into-household-sharing.md)
  — why the sharing upgrade preserves and migrates existing inventory.
- [adr/0003-model-inventory-dates-as-civil-days.md](./adr/0003-model-inventory-dates-as-civil-days.md)
  — why purchase and expiry are calendar days rather than instants.
- [adr/0004-remove-the-99-unit-quantity-cap.md](./adr/0004-remove-the-99-unit-quantity-cap.md)
  — why individual quantity commands accept any positive representable whole number.
- [adr/0005-make-saved-item-names-immutable.md](./adr/0005-make-saved-item-names-immutable.md)
  — why item identity cannot be renamed after saving in the first sharing release.
- [adr/0006-use-canonical-item-metadata-and-field-merges.md](./adr/0006-use-canonical-item-metadata-and-field-merges.md)
  — why grouped-item metadata uses one canonical member and accepts per-property conflict merging.
- [adr/0007-support-one-owner-installation-in-the-first-rollout.md](./adr/0007-support-one-owner-installation-in-the-first-rollout.md)
  — why the initial rollout assumes, but does not enforce, one installation per Household owner.
- [adr/0008-create-a-fresh-root-for-each-purchase.md](./adr/0008-create-a-fresh-root-for-each-purchase.md)
  — why every purchase gets causal context through its own hidden physical root.
- [adr/0009-use-household-epochs-as-the-only-clear-all-record.md](./adr/0009-use-household-epochs-as-the-only-clear-all-record.md)
  — why Clear All advances only the Household causal frontier.
- [adr/0010-treat-zero-quantity-as-a-revivable-projection.md](./adr/0010-treat-zero-quantity-as-a-revivable-projection.md)
  — why synchronized stock can reappear after a locally observed zero.
- [adr/0011-preserve-canonical-metadata-on-same-name-purchases.md](./adr/0011-preserve-canonical-metadata-on-same-name-purchases.md)
  — how same-name purchases preserve established metadata while honoring explicit edits.
- [adr/0012-omit-manage-sharing-from-the-first-rollout.md](./adr/0012-omit-manage-sharing-from-the-first-rollout.md)
  — why individual member management and its system UI are deferred.
- [adr/0013-require-manual-selection-after-invitation-acceptance.md](./adr/0013-require-manual-selection-after-invitation-acceptance.md)
  — why accepted Households appear in the picker without auto-selection state.
- [decisions.md](./decisions.md) — the legacy decision log for choices recorded before numbered
  ADRs; read it for prior rationale but record new decisions under `adr/`.

## Meta

- [AGENTS.md](./AGENTS.md) — conventions for maintaining this wiki. Read before editing any wiki file.
- [agents/domain.md](./agents/domain.md) — repository-specific domain glossary and ADR paths for
  installed engineering skills.
- [agents/issue-tracker.md](./agents/issue-tracker.md) — GitHub issue operations used by planning and
  triage skills.
- [agents/triage-labels.md](./agents/triage-labels.md) — canonical triage-state label mapping.
