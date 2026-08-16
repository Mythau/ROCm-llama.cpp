# Cohort Progress/Debt First-Pass Checklist

Status: components A, B, and C completed. Root synthesis is recorded in `COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md`. Active architecture documents remain unchanged pending user review. This does not authorize implementation, builds, runtime tests, commits, or source changes.

Purpose: replace categorical per-member scheduling-stage language with an ephemeral projection of authoritative execution progress and pending work, while retaining explicit controller-owned cohort policy phases.

## Governing distinction

```text
controller phase
    = persistent global scheduling policy

stream progress facts
    = ephemeral projection of authoritative slot/runtime state

derived work debt
    = prompt, sampled, speculative-verification, or replay work that may be proposed

logical row cost
    = target rows required to pay authorized debt in one committed manifest
```

Only committed logical request progress is monotonic. Prepared/speculative extent may expand or retract after verification. Physical KV/cache positions may shift, restore, evict, or rebuild. The first pass must keep these coordinates distinct.

## Component A — Authoritative source-state projection

Owner deliverable: an evidence-backed source map. Do not propose new stored counters until the current state has been proven insufficient.

- [ ] Trace the current authoritative fields and mutations for prompt extent, prompt progress, accepted output progress, sampled-token ownership, speculative proposals, verification, partial acceptance, rollback, replay, and completion.
- [ ] Trace `WAIT_OTHER`, `n_cmpl` parent/child activation, slot reuse, cancellation, and release effects on independently runnable work.
- [ ] Trace cache hit/restore, prompt checkpoints, context shift, SWA/hybrid/recurrent state, and distinguish logical request progress from physical target-KV position.
- [ ] Trace MTP target/draft alignment, NextN capture, archive endpoints, immediate/deferred/OFF modes, and the point at which target-only advancement prevents later backfill.
- [ ] Identify which existing values are monotonic, which are retractable iteration/speculative state, and which are mutable physical-storage coordinates.
- [ ] Determine whether one existing logical coordinate can anchor the projection or whether the projection must combine several existing facts.
- [ ] Record exact source paths and line regions for every conclusion.
- [ ] Identify any ambiguity that requires a controlled experiment rather than an architectural assumption.

Required output:

1. Field/owner/mutation/meaning table.
2. Event-to-progress transition table.
3. Recommended source-derived fact projection, without implementation.
4. Proven gaps, if any, that would require new authoritative state.

## Component B — Controller and batching contract integration

Owner deliverable: a contract delta for `COHORT_BATCHING_CONTROLLER_DESIGN.md`. Do not edit the document during the first pass.

- [ ] Define the minimal ephemeral `stream_progress_facts` vocabulary using only facts supported by Component A or clearly marked placeholders awaiting its evidence.
- [ ] Define derived debt classes: prompt debt, sampled-token debt, fresh speculative verification debt, mandatory replay debt, and no runnable target debt.
- [ ] Keep eligibility/compatibility facts orthogonal: independently runnable, adapter signature, speculative profile/mask, cache capability, multimodal/exclusive work, embedding/rerank, and aLoRA.
- [ ] Prove that no progress or debt field duplicates slot, speculative-runtime, checkpoint, cache, queue, or adapter authority.
- [ ] State how NORMAL prices decode/replay debt first and assigns actual residual logical rows to prompt debt.
- [ ] State how `COHORT_PREFILL` authorizes prompt debt only and closes its barrier when every live member has zero prompt debt.
- [ ] State how `COHORT_DECODE` and DRAIN authorize sampled/verification/replay debt only.
- [ ] State how INTERMISSION preserves visible text debt while authorizing no text target work.
- [ ] Recast early prompt completion as creation of sampled-token debt that is held behind the cohort barrier and consumed exactly once.
- [ ] Recast replay as already-prepared mandatory debt with known row cost, without introducing controller-owned replay state.
- [ ] Preserve the distinction between semantic progress/debt and logical row reservation; confirm speculative proposals are not free progress.
- [ ] Preserve the same committed-manifest identity through preparation, target execution, retry views, post-decode, and outcome reporting.
- [ ] Identify every architecture-document section, invariant, transition predicate, observability item, regression, and approval item needing amendment.
- [ ] Keep manifest-view-aware speculative processing, paged KV, prompt-checkpoint DRAM optimization, and dynamic mid-decode MTP reconstruction in deferred work; explain how the new seam enables them without absorbing them.

Required output:

1. Proposed fact/debt vocabulary and derivation rules.
2. Revised policy predicate table.
3. Authority/ownership audit.
4. Exact architecture-document edit catalogue.

## Component C — Phased migration, tests, and observability

Owner deliverable: a migration delta for `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md`. Do not edit the document during the first pass.

- [ ] Phase 0: specify baseline evidence that captures existing authoritative progress inputs, derived work classification, manifests, and outcomes without changing behavior.
- [ ] Phase 1: specify dormant projection/debt types and deterministic unit tests without acquiring scheduling authority.
- [ ] Phase 2: specify mechanical slot/runtime-to-fact translation under the legacy manifest producer.
- [ ] Phase 3: specify atomic NORMAL takeover using derived debt rather than categorical member stages.
- [ ] Phase 5: specify activation outcome -> refreshed speculative/progress facts -> row reservation ordering.
- [ ] Phase 6: replace cohort transition predicates with prompt/decode/replay debt predicates while retaining the six controller phases and hysteresis.
- [ ] Phase 8: add projection equivalence, frontier transition, debt classification, manifest continuity, and absence-of-duplicate-state regression coverage.
- [ ] Confirm Phases 4 and 7 require only terminology/telemetry integration unless source evidence proves otherwise.
- [ ] Preserve the server/non-server split: progress projection and scheduling policy remain server-local; common speculative/cache/model/backend mechanics remain unchanged.
- [ ] Define observability for committed logical progress, prepared/speculative extent, physical-position diagnostics, derived debt, row price, authorization, and outcome without high-cardinality Prometheus identities.
- [ ] Define cancellation, slot reuse, parent/child, cache restore, context shift, partial speculative acceptance, replay across cohort exit/intermission, and MTP-OFF survivor tests.
- [ ] Identify gates that prove the legacy categorical scheduling interpretation has been deleted when the new authority takes over.
- [ ] Identify any migration step that would temporarily create dual progress or scheduling authority.

Required output:

1. Phase-by-phase delta and unchanged-phase statement.
2. CPU regression and controlled-runtime validation delta.
3. Observability delta.
4. Authority-duplication and rollback audit.

## Root synthesis and review gate

After all three components report:

- [ ] Reconcile the proposed vocabulary against the source-backed field map.
- [ ] Reject any new persistent member state that merely mirrors an existing owner.
- [ ] Resolve whether the logical committed frontier is singular or a derived tuple.
- [ ] Confirm speculative expansion/retraction and physical KV movement are not mislabeled as monotonic committed progress.
- [ ] Produce one consolidated architecture delta before editing either active cohort document.
- [ ] Review the consolidated delta for effects on deferred work without moving deferred projects into the active plan.
- [ ] Obtain user approval of the consolidated delta before rewriting the design and phased implementation plan.
