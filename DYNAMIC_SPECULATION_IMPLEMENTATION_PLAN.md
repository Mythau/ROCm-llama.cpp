# Dynamic speculative decoding implementation plan

Status: authority-audited implementation plan for `rocm-yolo`.

This plan assigns every change to the component that owns the underlying truth. It intentionally excludes decode grandfathering, the KV-cache kill switch, the intermittent unified-cache slow-copy repair and general profiling/instrumentation.

Each task must leave the tree buildable and land the focused tests for its own behavior. The existing static speculative behavior remains the default until DS-07 activates the policy through an explicit server flag.

## Authority rules

- `common_speculative` owns loaded implementations, per-sequence eligibility, dispatch and speculative-cycle ownership.
- Each speculative implementation owns its private mechanical state. MTP alone owns whether its draft KV, `pending_h` and target boundary are synchronized.
- The server slot owns replay bookkeeping, pending demotion and the safe point at which a sticky demotion may commit.
- Cache and checkpoint containers are policy-free. They store/apply opaque components and report mechanical results.
- The admission coordinator owns occupancy decisions, task preparation, new-request masks and the decision to request demotion.
- Resident LCP/rewind code owns whether same-slot state was mutated.
- CLI and visibility code expose policy and existing state; they do not make scheduling decisions or invent counters.
- A mechanism task adds the smallest counters/state needed to prove that mechanism. DS-07 only exposes those fields.
- Reset at new-request admission is the only operation that may add eligibility. Slot release must not reset it because the completed prompt may still need to be cached with its old provenance.

## Audited execution order

| Order | Task | Owner | Main dependency |
|---:|---|---|---|
| 1 | DS-01 | Common eligibility control | MTP serializer `809956215` |
| 2 | DS-02 | Common dispatcher and ngram-mod | DS-01 |
| 3 | DS-03A | MTP implementation and narrow common bridge | DS-01, DS-02 |
| 4 | DS-03B | Common target requirements and server decode bridge | DS-03A |
| 5 | DS-04A | Common speculative-cycle ownership | DS-02, DS-03A |
| 6 | DS-04B | Server safe-demotion coordinator | DS-04A |
| 7 | DS-05A1 | Common speculative serialization and MTP serializer | DS-03A, DS-04A |
| 8 | DS-05A2 | Server capture call sites | DS-05A1, DS-04B |
| 9 | DS-06A1 | Pure occupancy policy | DS-01 |
| 10 | DS-06A2a | Side-effect-free selection and group reservation | DS-06A1 |
| 11 | DS-06A2b | Task preparation and attachment primitive | DS-06A2a |
| 12 | DS-05B | Policy-free RAM-cache primitive | DS-05A1, DS-05A2 |
| 13 | DS-05C | Prompt-checkpoint restoration | DS-05A1, DS-04B |
| 14 | DS-05D | Resident reuse transitions | DS-03A, DS-04B |
| 15 | DS-06B1 | Common admission mask/reset bridge | DS-03A, DS-05A1 |
| 16 | DS-06B2 | Complete server admission transaction | DS-05B, DS-05C, DS-05D, DS-06A2b, DS-06B1 |
| 17 | DS-07A | CLI contract | DS-06B2 |
| 18 | DS-07B | Visibility | DS-07A |
| 19 | DS-09 | Benchmark harness and production validation | DS-07B |

## DS-01: generic per-sequence eligibility

Status: implemented, compile-verified and reviewed. The temporary standalone test was removed; `TEST-WIN-001` remains uninvestigated. Not committed.

### Owner

`common_speculative` in `common/speculative.cpp` with declarations in `common/speculative.h`.

### Work

- Derive one immutable loaded-implementation mask from successfully constructed implementations.
- Add one eligible mask per sequence beside the existing common dispatch state.
- Add implementation-agnostic query, sticky-disable and reset operations.
- Make reset the only API that can add an eligible bit.
- Treat these as internal APIs with validated callers. Use the project's normal assertions for programmer errors instead of adding runtime fallback behavior.
- Do not add MTP synchronization state here.
- Do not call reset from server slot reset/release.
- Do not change dispatch behavior.

### Proof

- Loaded mask reflects constructed implementations, not merely requested types.
- Disable affects only the selected sequence/type and cannot be reversed except by reset.
- Existing static speculative tests remain unchanged.

## DS-02: fixed-mask ngram execution gating

Status: implemented, compile-verified and reviewed. The temporary standalone test was removed; `TEST-WIN-001` remains uninvestigated. Not committed.

### Owner

The common dispatcher owns eligibility filtering; ngram-mod owns its request-local cursors and shared hash pool.

### Work

- Under a fixed pre-request mask, skip disabled ngram `begin`, `draft` and `accept` execution completely.
- Preserve ngram-first implementation priority and fallback to the next eligible implementation.
- Keep the global ngram-mod hash pool resident.
- Reset all ngram-mod request-local fields at an enabled request begin, including `n_low`.
- Do not add a passive observation path for disabled requests in v1. Disabled decode history will not train the shared pool.
- Do not redefine, clear or expose `impl_last`; DS-04A owns its lifecycle.
- Do not change process/state serialization or operational masks mid-cycle.
- Add the minimal ngram proposal count needed to prove disabled execution is zero.

### Proof

- Disabled sequence performs zero ngram work and emits no ngram proposal.
- Enabled sequence still learns and proposes normally.
- Priority and generic fallback are unchanged.
- Real MTP fallback is proven later in DS-03A.

## DS-03A: MTP row mapping and synchronization lifecycle

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

MTP owns row compaction, draft-context processing and synchronization truth. The common dispatcher supplies an implementation-specific eligibility view without exposing MTP policy to the server.

### Work

- Add per-sequence MTP state: `UNKNOWN`, `SYNCHRONIZED` and `INVALID`.
- Distinguish:
  - `needs_mtp_mirroring = eligible && state != INVALID`;
  - `can_mtp_draft = eligible && state == SYNCHRONIZED`.
- Allow a fresh eligible `UNKNOWN` request to mirror authoritative rows and become synchronized.
- Replace the bulk hidden-row shift with explicit raw-target-index to compact-draft-row mapping.
- Build the MTP batch token by token: first active row uses `pending_h`; later rows use the corresponding prior raw target row.
- Read verification hidden rows by raw target index.
- Preserve and validate the grouped-per-sequence assumption; reject unsupported interleaving inside MTP.
- Defensively gate MTP draft on readiness. Keep acceptance routing under common-cycle ownership.
- Put MTP-local invalidation behind a generic common operation. It clears verification rows/buffers, batch indices, chain/index and sampler scratch without teaching the server those fields.
- Mark MTP `INVALID` when it skips or mismatches an authoritative row.
- Add minimal per-sequence mirrored-row and proposal counters at the MTP work boundary.

### Proof

- Unit-test row mapping with two grouped sequences, one disabled sequence and sub-batch boundaries.
- Detect unsupported interleaving.
- Prove `UNKNOWN` bootstraps to `SYNCHRONIZED`; prove a skipped row becomes `INVALID`.
- Q35 two-sequence integration: disabled sequence contributes zero MTP draft-context rows; enabled sequence drafts and advances only its own draft KV.
- Combined repeated-text test proves eligible MTP remains synchronized when ngram wins and MTP receives observer acceptance.

## DS-03B: generic per-target-view NextN mode

Status: implemented, compile-verified, benchmark-validated, reviewed and accepted. Not committed.

### Owner

Each speculative implementation declares its target-output requirement; common aggregates requirements; the server decode bridge applies the result to the exact `batch_view`. Llama context/model graph code remains the owner of masked/unmasked graph semantics.

### Work

- Replace constructor-time global target-output mutation with implementation requirement declarations where dynamic switching requires it.
- Aggregate requirements over eligible sequences present in the exact target view.
- Immediately before each target `llama_decode(ctx_tgt, batch_view)`, apply a generic target-output mode and keep it unchanged through matching speculative `process()`.
- Active MTP requires unmasked raw-row NextN output.
- A view with a NextN consumer uses `(enabled=true, masked=false)` so MTP receives dense raw target rows.
- A view with no NextN consumer uses the context default `(enabled=false, masked=false)`.
- Do not use `(enabled=false, masked=true)` as a disabled mode. On Q35, `masked=true` independently moves row selection ahead of the final-layer FFN and changes the target graph even when NextN extraction is disabled.
- Do not put a Q35-specific branch in server code. Common declares whether the exact view needs NextN; the server decode bridge applies the corresponding context mode.
- Dynamic Eagle3 and draft-context NextN switching are not part of the accepted scope; see `NEXTN-DYNAMIC-001` in `KNOWN_ISSUES.md`.
- Toggle per sub-view, not once for the assembled server batch.

### Proof

- Source trace proves `(false, true)` selects Q35's early-cropped final-layer graph while allocating and copying no NextN host output; the regression is therefore a target graph-shape problem rather than residual MTP execution.
- A genuine two-slot ngram-only A/B at batch 2048 / microbatch 512 recovered aggregate prefill from 2,786.2 t/s with `(false, true)` to 3,889.7 t/s measured and 4,064.8 t/s warm with `(false, false)`. The original YOLO mean was 4,090.5 t/s.
- MTP-required views retain `(true, false)` and DS-03A continues to discard inactive rows before draft-context processing.
- Repeated mode changes are supported by the existing graph key, which includes both NextN flags.

## DS-04A: common speculative-cycle ownership

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

The common dispatcher.

### Work

- Redefine `impl_last` as an active-cycle owner rather than a historical winner.
- Clear it before a genuinely new draft attempt, set it only when an implementation emits, and clear it after all acceptance callbacks complete.
- Preserve it across retained recurrent replay.
- Add sequence-keyed query and abandon operations.
- Always complete acceptance for the recorded owner even if demotion has been requested.
- Define observer acceptance centrally; eligible MTP continues receiving `accept(..., is_other=true)` when ngram owns the cycle.

### Proof

- New draft, no-draft, normal acceptance and observer acceptance set/clear ownership correctly.
- Replay preserves the owner until final acceptance.
- Abandon clears ownership without claiming target rollback.

## DS-04B: server safe-demotion coordinator

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

`server_slot` and server decode/replay lifecycle. It queries common-cycle state but does not inspect MTP internals.

### Work

- Add a pending-demotion mask as queued intent, not a duplicate eligible mask.
- Centralize the safe predicate in `slot.spec_cycle_idle()`:

```text
spec_draft.empty()
&& spec_i_batch.empty()
&& !spec_is_replay
&& !common_speculative_cycle_active(spec, seq)
```

- Add `request_spec_demote(mask)`, `finish_spec_cycle()` and `abort_spec_cycle()` slot operations.
- Commit one atomic common operation that sticky-disables eligibility and invokes implementation-local invalidation.
- If replay is pending, retain the request until final acceptance and commit immediately afterward.
- Route cancellation/error/release through `abort_spec_cycle()`.
- On abort, repair/truncate authoritative target and sampler state from the speculative checkpoint where possible. If rollback is impossible, invalidate the affected prompt instead of merely clearing vectors around speculative tokens.
- Do not reset completed-request eligibility on release.
- Add transition counters/reasons here; no occupancy logic.

### Proof

- Immediate demotion at idle boundary.
- Deferred demotion through recurrent replay and final acceptance.
- Accepted tokens and sampler rollback remain correct.
- Abort during an expanded/unverified draft cannot leave speculative tokens presented as authoritative cache state.
- Falling occupancy cannot cancel a pending or committed demotion.

## DS-05A1: structured speculative-state contract

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

Common speculative serialization decides whether state may be captured/restored; MTP owns its blob encoding and boundary validation.

### Work

- Replace global Boolean state requirements with per-sequence structured capture/restore status.
- Capture is permitted only when the implementation is eligible, MTP is synchronized and no cycle is outstanding.
- Keep magic/version/type/dimension/position and `pending_h` validation inside MTP.
- Do not add a redundant validity flag inside an existing blob. Blob absence structurally represents target-only; malformed blob validity is implementation-local.
- Validate once that at most one loaded implementation is stateful in v1.
- Do not serialize target/draft context bytes or demote a server slot here.

### Proof

- Synchronized MTP produces a valid state blob.
- Ineligible, invalid or cycle-active MTP returns a target-only capture status.
- Wrong type/version/dimension/position is rejected mechanically.
- More than one stateful implementation is rejected.

## DS-05A2: truthful capture wiring

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

Server RAM-prompt-cache and prompt-checkpoint capture call sites. Storage objects remain opaque.

### Capture transaction

```text
stable server-loop boundary
-> query speculative capture status once
-> capture target always
-> stateful + synchronized: capture full draft + speculative blob
-> stateful + unsynchronized: leave draft and speculative fields empty
-> stateless implementation with a draft context: preserve draft-only capture
-> publish the record only after all chosen components are complete
```

### Work

- Wire both RAM prompt save and prompt-checkpoint creation.
- For stateful speculation, canonical target-only representation is absence of both draft and speculative components.
- Preserve existing draft-only capture for stateless draft implementations such as draft-simple, DFlash/DSpark and non-recurrent Eagle3.
- Keep the existing `server_prompt_cache::alloc()` and fresh checkpoint `emplace_back()` flows. Do not preallocate a new speculative vector or create a duplicate local checkpoint transaction; the records are new and synchronously populated.
- Do not clear optional fields at these capture sites because neither object is reused. The reusable active-replay `slot.spec_ckpt` remains outside DS-05A2.
- Do not add policy/types/provenance interpretation to `common_prompt_checkpoint`.
- Do not alter verification checkpoints used by active speculative replay.

### Proof

- Synchronized capture publishes target plus a complete draft/spec pair.
- Ineligible/invalid capture publishes target-only.
- Stateless draft implementations continue publishing target plus draft without a speculative blob.
- Partial optional capture is never published.

## DS-06A1: pure occupancy policy

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

A dependency-light, model-free policy module.

### Work

- Accept immutable snapshots of occupied stream IDs/current masks, incoming group size, loaded mask and configured limits.
- Produce incoming mask(s) and sticky removals for existing sequence IDs. Admission can attach a reason when it consumes the plan; the pure evaluator does not need a redundant reason object.
- Count the incoming group in prospective occupancy.
- Only remove bits from existing masks; never promote a surviving request.
- Keep policy disabled by default and table-driven, including occupancy three.
- Do not inspect server slot states, tasks, cache, pointers or queues and do not log.

### Proof

- Exhaustive one/two/three/four policy table.
- Parent-group sizes produce the correct occupancy input.
- Deterministic plans; no mutable side effects.

## DS-06A2a: side-effect-free selection and group reservation

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

Server admission/resource selection.

### Work

- Build occupancy snapshots by treating every non-IDLE slot, including `WAIT_OTHER`, as occupied.
- Refactor `get_available_slot()` into side-effect-free selection that returns stable slot IDs and displaced-prompt/resident/RAM intentions.
- Select the parent and every child as one immutable local group before any mutation.
- Reservation means stable IDs in the local selection result, not a new slot state or revalidation framework; admissions are already serialized.
- Preserve explicit-slot behavior, LCP thresholds and ties, LRU tie ordering, and forward child-slot ordering exactly.
- Return `DEFER`/failure to `process_single_task()`; only the queue owns deferral.
- Do not save, load or clear cache state, attach tasks, apply policy or demote live requests.

### Proof

- Every non-IDLE state counts and IDLE cached slots do not.
- Parent plus children reserve the full stream count.
- Selection emits intentions without saving/loading/clearing cache state.
- Existing explicit-slot, LCP, LRU and child ordering decisions are unchanged.

## DS-06A2b: task preparation and attachment primitive

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

Server task preflight and slot attachment mechanics.

### Work

- Prepare an owned task, final LoRA vector, aLoRA invocation position, LoRA-derived resident-clear intention, constructed sampler, backend-sampler attachment choice and initial parent/child state.
- Validate tokens and resolve LoRA/aLoRA state without changing a slot.
- Construct samplers for every parent/child task before changing any slot.
- Prepare the complete group before any attachment.
- Define a simple non-failing attachment primitive. DS-06B, not DS-06A2b, invokes it inside the admission transaction.
- Keep `llama_set_sampler()` and resident clearing in final attachment/admission because they mutate the target context or displaced slot.
- Do not restore cache, apply speculative eligibility policy or demote live requests.

### Proof

- Invalid tokens, aLoRA configuration or sampler construction failure leaves every selected slot untouched.
- A complete parent/child group prepares before any task ownership or slot-state change.
- The attachment primitive performs no validation or fallible construction.
- No cache, speculative-policy or live-request lifecycle work is introduced.
- Failed/deferred preparation mutates nothing.

## DS-05B: policy-free RAM-cache take/apply

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

`server_prompt_cache` entry selection/application plus mechanical common-memory restore APIs.

### RAM restore transaction

```text
admission supplies immutable TARGET_ONLY or WITH_SPEC mode
-> take selected entry into one-owner state
-> apply target
-> on target success, commit prompt metadata and target reuse
-> optionally apply draft, then speculative blob
-> return structured mechanical result
```

### Work

- Separate entry selection/take from application.
- Return at least `{found, target, draft, spec, error/reason}`.
- Consume a taken entry exactly once.
- Treat target success as the durable partial-commit point.
- Optional draft/spec absence or failure keeps target and prompt metadata, clears optional destination state and reports failure.
- Never call `prompt_clear()` after target success solely because optional speculative state failed.
- Do not inspect masks, decide restore mode, demote slots, launch tasks or handle parent/child policy.

### Proof

- Valid cross-slot target+draft+spec application.
- Target-only application skips optional uploads.
- Missing/corrupt optional state preserves target reuse and consumes the entry consistently.
- Target failure is distinguishable from optional failure.

## DS-05C: prompt-checkpoint restoration

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

`common_prompt_checkpoint` supplies mechanical try-loads; server pre-decode checkpoint orchestration decides the ordered restore and fallback.

### Work

- Restore checkpoint target first and commit checkpoint-derived `n_past` on success.
- If the admitted request is eligible, attempt draft then MTP blob.
- Optional failure clears destination draft state and invokes the single DS-04B demotion operation.
- Never force a full cached-prefix prefill after a valid target checkpoint merely because MTP failed.
- Keep policy out of the checkpoint container.

### Proof

- Valid aligned checkpoint resumes MTP.
- Missing/corrupt/wrong-boundary MTP preserves target checkpoint reuse and performs zero later MTP work.
- Partial restore at known Q35 checkpoint boundaries follows the structured result.

## DS-05D: resident reuse synchronization transitions

Status: implemented, compile-verified and reviewed. Strict-extension transfer across the future explicit admission reset remains owned by DS-06B. Not committed.

### Owner

Same-slot resident LCP, rewind, exact-hit, context-shift and chunk-reuse paths.

### Work

- Before new-request reset, retain a transient fact describing whether the selected idle sequence had synchronized resident MTP.
- Transfer synchronization only for an untouched strict full-prefix extension.
- Shorter-LCP rewind, exact-hit mandatory one-token reevaluation, context shift and chunk reuse invoke DS-04B invalidation/demotion unless a synchronized checkpoint replaced target, draft and boundary together.
- Resolve or explicitly abandon any outstanding speculative cycle before mutating target/draft memory.
- Prefer maximum target reuse; never rewind additional target tokens solely to regain MTP.
- Do not store these transition rules in cache/checkpoint containers.

### Proof

- Strict aligned extension can retain MTP.
- Rewind, forced reevaluation, context shift and chunk reuse preserve target work but disable MTP.
- No context mutation occurs behind a merely queued demotion.

## DS-06B1: common admission mask/reset bridge

Status: implemented, compile-verified and reviewed. Not committed.

### Owner

`common_speculative` and each stateful implementation's mechanical readiness query.

### Work

- Expose read-only loaded, per-sequence eligible, draft-context and stateful implementation masks.
- Expose a non-serializing synchronized-stateful mask. MTP reports synchronized readiness from its own sync state; stateful Eagle reports whether its boundary state is present.
- Add a masked new-request reset that installs the exact incoming mask.
- Reset every implementation normally, except the included stateful implementation when the caller has already proven an untouched strict resident extension and requests preservation.
- Keep the existing full reset as the loaded-mask, no-preservation form.
- Do not name MTP/Eagle types in server code, capture/restore a blob, or add slot provenance.

### Proof

- Exact incoming masks cannot enable unloaded implementations.
- Normal reset clears all implementation-local request state.
- Proven strict-extension preservation retains only synchronized stateful state whose bit remains admitted.
- No serialized blob or duplicate provenance is introduced.

## DS-06B2: complete server admission transaction

Status: implemented, compile-verified and reviewed after correcting unsynchronized resident-prefix reuse and parent-release cleanup of `WAIT_OTHER` children. Not committed.

### Owner

The server admission coordinator. It composes DS-06A policy/selection with DS-05 storage mechanics and DS-04 demotion; it does not duplicate them.

### Transaction

```text
select/reserve the complete slot group
-> prepare and validate the whole task group
-> compute the prospective policy plan
-> capture displaced idle prompts using their old eligibility/synchronization
-> classify untouched strict resident extension
-> infallibly attach tasks and apply resident-clear intentions
-> reset new-request control with exact incoming masks
-> submit sticky demotion requests for existing live slots
-> apply any taken RAM entry using immutable restore mode
-> fall back to ordinary target prefill only if target restoration failed
-> enter pre_decode
```

### Work

- Treat attachment of the complete parent/child group as one commit; no partially launched group.
- Build active occupancy snapshots from every processing slot and pass immutable values to DS-06A1.
- Keep the internal policy-limit table empty until DS-07A configures it; empty policy preserves current static behavior.
- Save displaced state before new-request reset and before any LoRA resident-clear intention is applied.
- Prove strict-extension preservation only for a non-child request with no RAM replacement, no LoRA clear, a nonempty resident prompt that is a strict full prefix of the incoming prompt, synchronized stateful state, and an incoming mask that retains that bit.
- Do not serialize/restore a blob or create shadow provenance for strict extension.
- After successful attachment, request existing-slot demotions through DS-04B rather than changing masks directly.
- Use DS-05B `take/apply`; stop using the legacy Boolean `prompt_load` compatibility path in admission.
- A new request whose optional RAM state fails remains admitted with its target hit; perform exactly one draft/stateful demotion.
- Under MTP active limit one, every `n_cmpl>1` group is MTP-ineligible and uses target-only state. Generic MTP parent/child cloning is out of scope.
- Failed/deferred preparation consumes nothing and demotes nobody.
- Completion/cancellation changes only the next occupancy snapshot and never promotes survivors.
- Group cancellation remains task-lifecycle work; ensure parent/children cannot be stranded in `WAIT_OTHER`.
- Own debug admission/demotion reason events.

### Proof

- B arriving during A prefill causes a safe sticky demotion before A's next authoritative prompt batch.
- Occupancy-two cached entry uses target-only mode and performs zero MTP work.
- `n_cmpl=2` from idle counts as two streams and remains coherent.
- Failed/deferred group leaves live solo MTP untouched and consumes no cache entry.
- Cancellation/error release does not promote survivors; a later fresh solo request gets a fresh full mask.
- Displaced demoted prompt is captured before new-request reset.

## DS-07A: CLI contract

Status: implemented, compile-verified and reviewed. Nonempty mappings must cover every loaded implementation. Not committed.

### Owner

Server configuration and argument parsing.

### Work

- Store `spec_active_limits` in the server-only portion of `common_params`, not request speculative params, task params or request JSON.
- Add server-only `--spec-active-limit TYPE=N,...`.
- Parse syntax independently of option order.
- Reject malformed, unknown, `none`, duplicate, zero, negative and non-integer entries.
- Perform semantic validation only after `--parallel` defaults resolve; after actual speculative implementations are constructed, require a non-empty mapping to cover all and only loaded implementations.
- Reject dynamic mappings when draft-simple, Eagle3, DFlash or DSpark is loaded; v1 execution gating is complete only for MTP and n-gram implementations.
- Handle model-less router parent/child forwarding: forward the server option, skip construction-dependent validation in the router parent and validate in the model child.
- No flag means byte-for-byte current static behavior.

### Proof

- Valid and reversed-order forms.
- Syntax and post-resolution semantic failures.
- Unloaded/partially mapped implementation failures.
- Router forwarding and child validation.
- Omitted flag preserves behavior and response shape.

## DS-07B: visibility

Status: implemented, compile-verified and reviewed. No server executable or smoke test was run. Not committed.

### Owner

Server presentation/response code. It serializes state owned by earlier tasks.

### Work

- Log the effective mapping once at startup.
- Add the mapping to `/props` only when configured.
- Preserve the existing Boolean `/slots` `speculative` field; add separate/nested fields rather than changing its type.
- When policy is active, expose read-only per-slot phase, eligible types, MTP readiness and pending demotion.
- An immutable final per-request snapshot is deferred: final results have protocol-specific object, array and SSE event shapes with no common additive response envelope. Adding it here would require schema-specific response machinery rather than serializing existing state at one clean boundary.
- Do not invent profiling counters in this task. DS-02/03/04 deliberately landed without telemetry; zero-work proof remains a later focused validation concern rather than DS-07B scope creep.
- Keep admission/demotion decision logging in DS-06B.
- Update `docs/speculative.md` and the documentation generator source, not generated README output by hand.

### Proof

- Additive schema fields are omitted when the policy is inactive.
- `/props` reports the effective configured mapping.
- `/slots` shows live transition state without changing existing fields.
- Final-response visibility remains a separately scoped response-schema task if it is still wanted.
- Runtime one/two/four-slot proof remains in DS-09; this task does not add or run a smoke harness.

## DS-09: benchmark harness and production validation

Status: complete, compile-verified, production-validated and cumulatively reviewed. Partitioned short smoke, 8K/512 screen, 8K/4K dynamic/fixed mechanism controls, synchronized-MTP RAM restore and target-only RAM restore all passed. No policy-usefulness or speculative-acceptance verdict is claimed. Not committed.

### Owner

Benchmark scripts, local artifacts and sanitized documentation only. DS-09 must not modify dispatcher, scheduler, serializer, policy or endpoint schemas. A product defect returns to its owning task as a separately named corrective commit.

### Fixed production contract

- RX 7900 XTX gfx1100 plus R9700 gfx1201; R9700 main GPU.
- ROCm 7.14; peer copy compiled off; HIP graphs off; `ROCBLAS_USE_HIPBLASLT=0`.
- Q35B Q8_0 with embedded MTP; BF16 target and draft KV; flash attention; full GPU residency.
- Four-slot server for every dynamic and fixed comparison: `--parallel 4`, context 50,176, batch 8,192, ubatch 1,024.
- Occupancy is varied by submitting one, two or four active requests. Never resize the server/context for the one- and two-request tests.
- Require at least 1 GiB free on the 7900 XTX and 2 GiB on the R9700 with no CPU layer/KV offload.

### Harness corrections

- Separate `n_parallel=4` from `active_requests=1|2|4` in the concurrency harness.
- Record one high-resolution timestamp in the barrier release action and absolute first-token timestamps per request.
- Aggregate prefill is total actual prompt tokens divided by release-to-latest-first-token time.
- Remove summed/multiplied per-slot prompt throughput from the sanitized schema.
- Keep active decode as earliest absolute first token through latest completion.
- Restart server between configurations because ngram-mod shared state persists.
- Evaluate performance gates on the median of three measured waves and publish all values plus mean/range.

### Stages

1. **Configuration/capacity gate:** record build/model/command/env, verify compile/runtime flags and both target/draft residency, then freeze the four-slot configuration.
2. **Short smoke:** partitioned KV, short one/two/four waves, exact masks and coherent completion. Mechanism-level zero-work behavior is owned by the reviewed DS-02/03 gates; DS-09 does not add profiling counters to re-prove it.
3. **Screen:** partitioned 8K prefill plus 512 or 1,024 decode, one warmup and one measured wave.
4. **Final throughput:** partitioned 8K/4K, one warmup plus three measured waves:
   - dynamic at one, two and four active requests;
   - fixed combined at one;
   - fixed ngram at two;
   - fixed no-spec at four;
   - disjoint prompts as a stable mechanism workload. Whether a speculative implementation benefits a particular prompt is outside this validation.
5. **Unified cache-only validation:** reuse lower-level cache harness primitives for three separate cases:
   - four-stream original/churn/restore target-cache regression;
   - solo synchronized-MTP entry churned and restored solo;
   - target-only entry created at occupancy two, churned and restored solo without promotion.

### Gates

- Exact requested token count; no crash, HIP error, NaN, allocator failure, NUL/replacement character or exact foreign sentinel.
- Model-behavior warnings such as a mutated self-sentinel are reported separately from backend corruption.
- Effective masks match policy. Disabled-work correctness relies on the reviewed mechanism gates and runtime output/performance behavior rather than new profiling instrumentation.
- Dynamic one/two prefill stays within 5% of matching fixed controls. Speculative decode throughput is recorded but is not a mechanism gate because acceptance varies with generated content.
- Dynamic four stays within 7% aggregate prefill and 5% active-decode/end-to-end of true no-spec.
- Valid and target-only restores preserve target cache hits without full prefill.
- For synchronized restore, prove a target cache hit plus restored `mtp_ready` and an eligible MTP mask. Draft acceptance is not a cache-mechanism gate.
- Publish two verdicts: core dynamic-policy correctness/performance and unified-cache restoration. The known `KV-RESTORE-001` latency issue does not automatically reject the scheduler feature.

## Explicitly deferred

- Decode grandfathering or any phase-aware retention limit.
- Live promotion/re-enabling inside a surviving request.
- Passive ngram learning while ngram execution is disabled.
- Generic MTP state cloning for parent/child completions.
- Multiple stateful speculative implementations.
- Per-row selective NextN graph output inside a mixed view.
- Freeing resident MTP weights/recurrent rollback storage dynamically.
- Client-controlled per-request speculative policy.
- KV-cache kill switch and unified-cache slow-copy repair.
- General profiling/instrumentation.

## Final dependency shape

```text
DS01
 |- DS02 -> DS03A -> DS03B
 |              `-> DS04A -> DS04B ------------------.
 |                    `-> DS05A1 -> DS05A2 -> DS05B  |
 |                                  `-------> DS05C  |
 `-> DS06A1 -> DS06A2                         DS05D  |
                                                  \  |
                                                   DS06B
                                                     |
                                                  DS07A
                                                     |
                                                  DS07B
                                                     |
                                                   DS09
```

The linear delivery order above is authoritative where this compact graph omits secondary dependencies.
