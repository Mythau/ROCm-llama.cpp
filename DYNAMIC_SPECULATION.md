# Dynamic speculative decoding implementation inventory

Status: design inventory, not an implementation plan.

Implementation plan: [DYNAMIC_SPECULATION_IMPLEMENTATION_PLAN.md](DYNAMIC_SPECULATION_IMPLEMENTATION_PLAN.md)

## Objective

Select speculative implementations per request according to server occupancy. Request phase matters only when finding a safe boundary at which a sticky demotion can commit. The policy is configured when `llama-server` starts. Clients do not select their own speculative mode.

The intended policy is:

- One active request: ngram-mod and MTP.
- Two active requests: ngram-mod only in the baseline policy.
- A second active request demotes MTP for every active request, including an established decoder.
- A request still processing its prompt loses MTP when a second request arrives.
- Higher occupancy disables implementations according to configurable limits.
- A speculative implementation disabled for a request is never re-enabled during that request.
- The next newly admitted solo request may use MTP after a full prefill or a synchronized cache restore.

The three-request policy must remain configurable. It must not be hard-coded while benchmark evidence is incomplete.

## 1. Startup policy

Add server-only policy mappings:

```text
--spec-active-limit draft-mtp=1,ngram-mod=2
```

`active-limit` is the maximum occupied-stream count at admission and while a request is processing its prompt. Parent requests with multiple completion children therefore count as multiple streams.

Requirements:

- No policy flags means current static speculative behavior is unchanged.
- The first implementation supports loaded MTP and n-gram implementations only. Other draft implementations remain static-only.
- The active count includes the incoming request.
- Reject unknown, duplicate, unloaded or malformed implementation mappings.
- Limits must be between one and `--parallel`.
- Keep this policy out of the request JSON schema.

## 2. Per-request eligibility

The common speculative dispatcher needs one loaded-implementation mask and a per-sequence eligibility mask. This is the sole eligibility owner.

Related state remains with the component that owns its truth:

- The MTP implementation owns whether its private draft KV and boundary state are synchronized.
- The server slot owns prompt/decode phase, replay bookkeeping and pending demotion intent.
- Cache/checkpoint containers own opaque component bytes, not policy or eligibility.

`mtp_synced` means all of the following are true:

- MTP has processed every authoritative target row for the request.
- Target and MTP draft positions match.
- `pending_h` belongs to that exact boundary position.
- No verification cycle is outstanding.

Rules:

- Eligibility may only decrease during a request.
- Falling occupancy does not promote surviving requests.
- Slot reuse starts a new eligibility decision only after the displaced idle prompt has been saved with its old provenance.
- Request completion does not reset eligibility immediately because the completed prompt may still be cached later.

## 3. Safe transition boundary

Demotion must occur between speculative cycles, after an outstanding draft has been verified or discarded.

Before disabling an implementation for a request:

- Finish target verification of the current draft.
- Call `accept()` for every still-eligible implementation. If ngram-mod produced the winning draft, MTP still needs `accept(..., is_other=true)` to advance its boundary state.
- Clear the request's pending speculative draft bookkeeping.
- Resolve `spec_draft`, `spec_i_batch`, `spec_is_replay` and the common speculative `impl_last` selection.
- Preserve the authoritative target KV state.
- Stop future process, draft and accept calls for that implementation and sequence.

MTP must not be disabled halfway through a target verification batch.

## 4. Speculative core gating

The common speculative wrapper currently calls every loaded implementation. It needs per-sequence eligibility filtering for:

- `begin()`
- `process()`
- `draft()`
- `accept()`
- State save and restore

The eligibility API should be implementation-agnostic. The scheduler selects implementation types; common dispatch supplies each implementation with the applicable sequence view. Implementations retain authority over their private readiness and state.

`process()` is passed one multi-sequence target batch. Its eligibility mask must preserve the original target-output row indices while selecting only eligible sequence rows for each implementation.

The current state API stores only the first stateful speculative implementation. The first dynamic version must reject configurations containing more than one stateful implementation, or replace the blob with a versioned per-implementation envelope. Ngram-mod plus MTP is valid because ngram-mod has no model state.

## 5. MTP gating

MTP requires more than skipping `draft()`. A fresh eligible request begins with MTP synchronization unknown, so it must be allowed to mirror authoritative rows before it is ready to draft.

When MTP is disabled for a sequence:

- Do not mirror its prompt or decode rows into the MTP context.
- Do not draft with its KV cache.
- Do not update its pending hidden state.
- Do not process acceptance state for it.

Demotion must atomically invalidate MTP synchronization and clear its per-sequence verification rows, batch indices, chain scratch and outstanding-cycle state.

Before each target `llama_decode`, use unmasked target NextN extraction `(enabled=true, masked=false)` only when that exact target view contains at least one sequence that still needs MTP mirroring. This includes eligible `UNKNOWN` MTP state and excludes `INVALID` state. A view with no consumer must use the normal context mode `(enabled=false, masked=false)`. Do not use `(false,true)` as a disabled mode: Q35 reads `masked` independently and selects an early-cropped final-layer graph. Do not toggle the mode between target decode and the matching speculative `process()` call.

For a mixed batch, the initial implementation may still extract target nextn rows globally and discard rows for ineligible sequences. Selective graph extraction is a later optimization and is not required for correctness.

This target-view switching contract is accepted for Q35 MTP plus ngram. Dynamic Eagle3 and draft-context switching are excluded until their processing and eligibility semantics are handled separately; see `NEXTN-DYNAMIC-001` in `KNOWN_ISSUES.md`.

MTP state cannot catch up after its process path has skipped an authoritative target row. Therefore:

- Demotion is sticky for the current request.
- A later solo request can use MTP after processing its prompt from the beginning.
- A cache restore can use MTP only when target KV, MTP draft KV and serialized MTP boundary state are synchronized.
- A cache entry saved after MTP skipped target rows must not be treated as MTP-synchronized.

Demotion and desynchronization are related but distinct. A request is mechanically desynchronized on the first skipped target row. A conservative first version may invalidate MTP immediately when demotion is committed.

Checkpoint and RAM-cache MTP serialization began in commit `809956215`. It is a first-pass serializer proven for aligned Q35 checkpoint and RAM-cache restores. It is not yet general proof that every direct latest-state rewind has enough MTP boundary history.

Runtime gating removes MTP compute for ineligible sequences, but it does not recover every cost of launching an MTP-capable server. MTP fixes target `n_rs_seq=3`, expands recurrent rollback storage fourfold, changes ubatch grouping and keeps MTP weights and compute buffers resident. A fully gated server may therefore remain slower or use more VRAM than a separately launched no-spec server.

## 6. Ngram-mod gating

Ngram-mod has no model KV cache and is cheap to keep resident.

Requirements:

- When ngram is eligible, preserve its existing prompt/token learning and proposal behavior.
- When ngram is disabled for a request, skip its `begin`, `draft` and `accept` work completely in v1.
- Do not add a passive disabled-request observation path in v1; its decode history will not train the shared pool.
- Permit immediate per-request admission or demotion without model-state reconstruction.
- Keep the shared hash pool resident across occupancy changes.

The existing implementation priority remains useful: ngram-mod attempts a draft first, and MTP is the fallback when ngram-mod has no draft.

## 7. Occupancy and phase policy

The scheduler computes or applies policy when:

- A request is admitted.
- A request completes or is cancelled, affecting only the next admission snapshot.
- A cache restore determines whether MTP state is synchronized.

Required behavior examples:

1. Request A starts alone: A receives ngram-mod and MTP.
2. Request B arrives while A is in prefill: A is demoted to ngram-mod; B receives ngram-mod.
3. Request B arrives after A entered decode: A is demoted to ngram-mod at a safe boundary; B receives ngram-mod.
4. Occupancy exceeds an implementation's active limit: existing requests are demoted at safe boundaries.
5. Occupancy later falls: surviving requests remain demoted.
6. All requests finish and request C starts alone: C receives ngram-mod and MTP.

## 8. Cache-state integration

Cache restoration must determine per-request eligibility before generation begins. Admission eligibility should be known before optional MTP draft-state upload where possible.

- Valid synchronized MTP state: MTP may remain eligible if occupancy permits.
- Missing, invalid or position-mismatched MTP state: preserve target KV and demote MTP for that request.
- A request that is MTP-ineligible by occupancy may save and load a target-only cache entry even though MTP is loaded globally.
- Skip uploading MTP draft state for an ineligible request; clear its destination draft sequence and mark it unsynchronized.
- Cache state captured after MTP skipped target rows: restore target KV but keep MTP disabled.
- A synchronized checkpoint retained from before demotion remains mechanically valid, although the first version need not sacrifice newer target reuse merely to regain MTP.
- Ngram-mod may operate from restored token history without an MTP state dependency.

Apply target state first and treat MTP state as optional. Cache loading needs a structured result or equivalent distinction between `target_restored` and `mtp_restored`.

The current MTP serialization patch forces prompt reprocessing on invalid speculative state and can clear an otherwise valid target hit. Replace that fallback with target-KV preservation after per-request gating exists.

An MTP state blob must include the type/format discriminator, version, dimension and boundary position needed for implementation-local validation. Position equality by itself does not prove that `pending_h` was produced by the last authoritative target batch. A synchronized draft/blob pair is present only when the capture contract approved it; absence of both is the canonical target-only representation, so a redundant validity flag inside a present blob is unnecessary.

A synchronized checkpoint may resume MTP and replay its unmatched suffix. Target-only reuse, a direct full-state rewind without enough boundary history, or a checkpoint captured after MTP fell behind must retain maximum target reuse and demote MTP. Do not rewind extra target tokens solely to regain MTP in the first version.

The serialized MTP boundary is approximately 8.02 KiB per checkpoint. The meaningful restore cost is the existing MTP context state: approximately 40.4 MiB for the full state plus selected checkpoint in the measured Q35 run.

## 9. Visibility

Expose enough state to verify the policy without adding a profiling subsystem:

- Log the effective startup mappings once.
- Expose the effective server policy through `/props`.
- Preserve `/slots`' existing Boolean `speculative` field and add policy-active phase, eligibility, synchronized stateful readiness and pending-demotion state only when the policy is configured.
- Do not create speculative profiling counters as part of policy visibility.
- Defer immutable final-response snapshots unless a separately scoped response-schema change establishes one common additive boundary across the native, OpenAI, Responses and Anthropic object/SSE shapes.

## 10. Tests required

Parser tests:

- Valid mappings and reversed option order.
- Default behavior unchanged when mappings are absent.
- Unknown, duplicate, unloaded, zero and out-of-range limits rejected.

State-machine tests:

- Eligibility only decreases within a request.
- Prefill demotion at rising occupancy.
- No promotion when occupancy falls.
- Fresh slot reuse receives a new admission decision.

Server integration tests:

- Solo request uses ngram-mod plus MTP.
- Second request during prefill demotes both requests to ngram-mod.
- Second request during decode demotes MTP for the established decoder at a safe cycle boundary.
- Higher occupancy follows configured limits.
- Synchronized RAM-cache restore can resume MTP.
- Invalid or demoted RAM-cache state reuses target KV without MTP.
- A request that is MTP-ineligible while MTP is globally loaded can save and restore a target-only cache entry.
- Missing, corrupt, wrong-version, wrong-dimension and wrong-position MTP blobs preserve the target hit and execute zero MTP calls.
- Unified RAM restore into another slot ID applies eligibility and state to the destination sequence.
- Direct latest-state restoration with mandatory one-token reevaluation follows the documented MTP fallback.
- Partial restores at the measured 7,164- and 8,188-token checkpoints resume only from synchronized boundaries.
- Cache capture before and after the first target row skipped by MTP produces the expected validity state.
- Configurations with multiple stateful speculative implementations are rejected unless a typed multi-state envelope is implemented.
- Output remains coherent through each transition.

Performance validation:

- Compare one, two and four active requests against the existing fixed-mode baselines.
- Confirm MTP prefill work disappears for ineligible requests.
- Confirm ngram-mod-only requests do not execute MTP draft-context work.
- Confirm the single-request combined-mode advantage remains.
- Compare restored MTP first-cycle acceptance with an equivalent fresh continuation.
- Compare fully gated resident MTP against a separately launched no-spec server to quantify irreducible MTP overhead.

## 11. Explicitly separate work

These are not part of dynamic speculative admission:

- The KV-cache kill switch.
- The intermittent unified-cache slow restore in `KNOWN_ISSUES.md`.
- Freeing resident MTP weights or recurrent rollback buffers dynamically.
- Re-enabling MTP in the middle of a surviving request.
- Selective target nextn graph output for individual rows in a mixed batch.
- Client-controlled per-request speculative settings.

## Smallest viable implementation boundary

The first working slice should contain:

1. Per-sequence common eligibility plus MTP-owned synchronization state.
2. A one-way MTP demotion operation committed only at a clean speculative-cycle boundary.
3. Eligibility-aware `begin`, `process`, `draft`, `accept`, state save and state restore.
4. Mandatory target nextn suppression for batches with no MTP-eligible sequence.
5. Target-first cache restoration that preserves the target hit and demotes MTP when optional MTP state is invalid.
6. A fixed internal test policy: one active request gets both, two get ngram-mod, four get neither; keep three configurable in the test harness.
7. A comparison against fixed both, fixed ngram-mod and true no-spec servers.

General CLI mappings follow after this slice proves that fully gated MTP work actually disappears and cache fallback remains correct. Decode retention/grandfathering is explicitly deferred.
