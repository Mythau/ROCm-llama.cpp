# Cohort Batching Phased Implementation Plan

Status: reviewed migration plan for architecture consultation. This document does not authorize implementation.

Architecture contract: `COHORT_BATCHING_CONTROLLER_DESIGN.md`.

Source inspected: current working tree based on commit `91a5c4911c86fa9e8b85fda27be0e6abeb75b574`, including the pre-existing local speculative/server changes. Those user-owned changes were not modified by this architecture work.

Working-tree reconciliation note: the working tree currently contains the Phase 5 post_decode generating-scan edit in `tools/server/server-context.cpp` (pre_decode scan removed, post_decode scan added, capture-finalize-on-denial added) as a pre-landed change on top of the committed Phase 1 (dormant contracts, `c448db2d6`), while the second legacy MTP call site (prompt-completion transition) remains live. Phase 2 has not started. This pre-landed edit must be re-verified against the final Phase 5 design when Phase 5 lands.

## Accepted structural direction

The monolithic `namespace inference_scheduler` proposal is retired. The durable mechanism has one scheduling-policy committer and several explicitly bounded components:

- `inference::identity`: value-only strong `stream_key`, `cohort_id` and `iteration_id` types.
- `inference::profile`: value-only immutable adapter/speculative profile types.
- `inference::control`: global phase machine, monotonic cohort/iteration identities, exact cohort membership, immutable cohort profiles, stream classification and `R`, barriers, sequencing, explicitly named commands, sole final target authorization and committed prompt cursor.
- `inference::admission`: candidate-set proposal plus the sole exact-scope adapter/speculative formation assessment.
- `inference::batching`: pure pending-work derivation, NORMAL compatibility grouping and MTP activation-set proposals from speculative eligibility facts, worst-case pricing, atomic decode-block packing, contiguous prompt grants and next prompt-cursor proposals.
- Existing global `server_queue` type: ordered ready/deferred/leased task ownership, queue-owned lease values and cancellation visibility; it is not also a namespace.
- `server_inference`: a passive `snapshot_reader` and one `admission_adapter` that plans and mechanically applies the same queue-lease-bound exact placement transaction.
- `server_execution`: one typed `executor` façade for every control-authorized cache/speculative initialization, reconciliation/preparation, target/external/model-mutation operation, mechanical retry view, and complete iteration-tagged outcome.
- Existing speculative policy/runtime: eligibility and mechanics respectively.

The authority rule in every phase is:

```text
admission/batching component calculates an exact proposal
    -> inference::control emits the corresponding exact command
    -> server adapter applies mechanically
    -> tagged outcome refreshes facts at a quiescent boundary
```

No proposal authorizes work. There is one controller, but there is no giant scheduler subsystem or umbrella namespace.

Initial source placement remains server-local while interfaces are proven:

```text
tools/server/inference-control.{h,cpp}
tools/server/inference-admission.{h,cpp}
tools/server/inference-batching.{h,cpp}
tools/server/inference-identity.h
tools/server/inference-profile.h
tools/server/server-inference-snapshot.h
tools/server/server-inference.{h,cpp}
tools/server/server-execution-outcome.h
tools/server/server-execution.{h,cpp}
```

Snapshot/outcome DTO headers depend only on identity/profile values and existing server/runtime value declarations; they never include control or executor implementations. Control may consume those DTO contracts, while adapters/executors depend on control command types. This keeps the compile-time graph one-way even though runtime outcome flow returns to control. An individual policy component may later move to `common` only when its interface is genuinely host-neutral. Source location is not used to pretend neutrality, and no generic `inference::types`, `inference::facts`, `inference::utils` or `inference::scheduler` bucket is introduced.

## Corrections incorporated from independent review

This plan incorporates the following code-derived corrections:

1. Admission sweeps are queue-owned cancellation-aware leases, not host-local swapped vectors.
2. Each immediate inference continuation first passes through the queue/control sweep so cancellations and controls can win.
3. Multimodal direct target execution receives scoped controller authorization before sole target-work authority is claimed.
4. Prompt reconciliation is mutating committed work, not speculative inspection.
5. Admission ordering is lease, reservation-aware placement, complete-scope raw speculative/cache capability and restore-mode facts, admission-owned formation assessment/proposal, control accepted-set/profile commit, minimal attachment ownership cutover, exact-pair reporting, FORM cohort binding or NORMAL initialization choice, mechanical speculative/cache initialization, and lease resolution.
6. Retry metadata preserves the complete sampled/speculative verification union as one indivisible prefix, permits partitioning only the prompt tail, and defines an explicit non-slicing retry/failure gate when the prefix cannot fit.
7. NORMAL prompt completion gives control an action boundary before existing deferred-MTP activation and `common_speculative_begin()`; cohort prompt completion uses its already frozen immediate/OFF profile and performs no activation.
8. Exact `COHORT_ENTRY_DRAIN` scope includes generating, prompt, partial-prompt and `WAIT_OTHER` incumbents; decode-family members drain, held prompt-family members seed FORM, and no active cohort exists yet.
9. Rollback is supported in reverse dependency order, not by arbitrarily reverting a lower phase under its dependants.
10. C++17 fact aggregates use ephemeral owning vectors passed by `const &`; the plan does not introduce a span polyfill.
11. Reconciled prompt coverage is a tagged outcome of controller-authorized mutating reconciliation, not a passive read or adapter-owned decision.
12. One monotonic `iteration_id` correlates distinct activation, decode-preparation, prompt-reconciliation and `target_batch_commit` commands; only the last authorizes target execution.
13. `server_inference::snapshot_reader` reports passive lifecycle/dependency/capability facts; `inference::control` alone defines exact formation scope, classifies streams, derives lifecycle/task blockers and `R`; `inference::admission` alone calculates adapter/speculative compatibility for that supplied scope.
14. Policy consumes only one `iteration_completion`. For target iterations, every `batch_view` and mandatory post action settles before that completion; admission-only, zero-work, model-mutation and terminal-failure iterations use the same closure contract without fabricating target results.
15. Logical current-task progress is lifecycle-gated `(reconciled_prompt_coverage, output_committed_count)`; prepared extent and physical KV/cache positions remain separate.
16. Pending work, priced proposals and authorized work are separate concepts. Prepared fresh blocks are tagged preparation outcomes, not rediscovered candidate facts.
17. Phase 3 enumerates and deletes categorical target-scheduling authority while retaining mechanical lifecycle translation and one isolated legacy NORMAL MTP-timing exception until Phase 5.
18. Shared value vocabularies, passive snapshots, proposals, control commands and execution outcomes have distinct namespaces and one-way header dependencies.
19. `server_context::update_slots()` is the mechanical pump, never a second policy controller.
20. Placement is one exact queue-lease-bound plan applied once; attachment never reruns allocation.
21. Operation classes distinguish immediate service, boundary-gated model mutation, individually reviewed slot/cache mutation and ordinary inference admission.
22. Threshold crossing creates pre-cohort entry intent only. All exact-scope decode-family work drains while prompt-family work is held; FORM may bind only after the complete formation scope is decoder-free.
23. One semantic producer owns each field: snapshots own raw/lifecycle-gated facts, reconciliation outcomes own reconciled coverage, speculative/replay owners own actual blocks, batching owns pending-work derivation/pricing, admission owns formation assessment, and control owns scope/blockers/`R`/authorization.

## Accepted progress, pending-work and iteration model

The controller stores no per-member lifecycle stage, progress tuple, pending-work set, reconciliation result, sampled token, prepared block, replay flag or physical position.

At a legal decision boundary, current-task progress is projected as:

```text
(reconciled_prompt_coverage, output_committed_count)
```

- Reconciled coverage exists only after control commits exact reconciliation membership and existing cache/checkpoint/speculative owners finish that mutating stage.
- Output-committed count is lifecycle-gated `n_decoded`, not raw speculative acceptance. WAIT_OTHER, STARTED, unreconciled/incomplete prompt and DONE_PROMPT-before-sampling project zero even if reused-slot fields are stale.
- A pending sampled input is already output-committed but still owes one target evaluation.
- Prepared speculative extent may expand or retract. Physical prompt/KV/checkpoint/archive state may shift, restore, shrink, evict or rebuild.

Pending debt is a phase-neutral derived set with five classes: prompt/reconciliation, sampled-token, fresh-verification, mandatory-replay, and none (no runnable target debt). `inference::batching` prices a proposal for it; only an `inference::control` commit creates authorized work. Barriers and INTERMISSION preserve visible pending debt while withholding authorization.

One monotonic per-process `inference::identity::iteration_id` correlates all commands and outcomes until one control-owned `iteration_completion`. A target iteration includes preparation commands, one `target_batch_commit`, its `batch_view` values and one complete `target_batch_outcome`; admission-only, zero-work, model-mutation and terminal-failure iterations close through other explicit completion payloads. The iteration is transient even though its allocator counter is persistent. No policy refresh occurs before completion.

## Accepted adapter and speculation scope

- A cohort has one immutable adapter signature: the exact ordered adapter set and exact scales.
- Base/no-LoRA is the empty signature.
- Identical static signatures may batch concurrently without copying adapter weights.
- Mixed active signatures prevent cohort entry and remain in NORMAL until they clear.
- Another signature arriving during a cohort remains queue-owned deferred until the boundary.
- Global `/lora-adapters` changes wait for a cohort boundary.
- aLoRA is excluded from cohort mode initially.
- Cohorts have no heterogeneous adapter lanes, lane cursor or lane-fairness policy; only prompt-member rotation remains.
- Every cohort freezes one homogeneous speculative profile before cache restore, attachment, or prompt work.
- Cohort MTP is either OFF for every member or IMMEDIATE for every member for the complete lifecycle. Deferred MTP is not a cohort profile.
- MTP-OFF uses target-only prefill and performs no NextN hidden-state capture, DRAM archive allocation/copy, deferred backfill, activation attempt/scan, or MTP verification.
- MTP-IMMEDIATE is legal only when every member can enter and retain immediate MTP from formation through prefill/decode, has an immediate-compatible cache restore or can prefill immediate from scratch, and cannot require a stateful demoting context shift within its declared lifetime; otherwise formation chooses MTP-OFF.
- LoRA-active cohorts are always MTP-OFF.
- An incumbent LoRA stream reaches a safe MTP idle/demotion boundary before cohort freeze.
- Ngram speculation remains eligible for LoRA-active cohorts.
- NORMAL retains its existing dynamic immediate/deferred/target-only policy as a separate authority-migration concern.
- Because the immutable cohort profile is final before batch planning, row reservation uses final MTP eligibility from the outset. There is no same-iteration cohort activation, so the earlier activation-before-row-reservation blocker does not apply to cohort mode.
- Genuine dynamic mid-decode MTP reconstruction is unsupported and remains follow-on research.

## Accepted cohort identity model

Control owns dedicated monotonic per-process cohort and iteration identities; shared identity/profile types remain value-only:

```cpp
namespace inference::identity {
struct stream_key {
    int32_t slot_id;
    int64_t task_id;
};
struct cohort_id { uint64_t value; };
struct iteration_id { uint64_t value; };
}

namespace inference::profile {
enum class cohort_mtp_mode {
    OFF,
    IMMEDIATE,
};

struct cohort_speculative_profile {
    cohort_mtp_mode mtp;
    uint32_t non_mtp_eligible_mask;
};
}

namespace inference::control {
struct active_cohort {
    inference::identity::cohort_id id;
    inference::profile::adapter_signature adapters;
    inference::profile::cohort_speculative_profile speculation;
    std::vector<inference::identity::stream_key> members;
    size_t prompt_cursor;
};

struct control_state {
    phase current_phase;
    uint64_t next_cohort_id;
    uint64_t next_iteration_id;
    std::optional<active_cohort> cohort;
    std::optional<inference::identity::stream_key> intermission_task;
};
}
```

The identity domains are deliberately separate:

- `task_id`: one task/request lifecycle.
- `slot_id`: the current physical execution container.
- `stream_key { slot_id, task_id }`: exact stream identity, preventing slot-reuse inheritance.
- `cohort_id`: stable scheduling-group lifecycle.
- `iteration_id`: one snapshot-to-complete-outcome scheduling/execution transaction.
- `lease_id`: queue-owned admission transaction, which may abort or exist outside cohort formation.

`intermission_task` is controller-owned scheduling identity only. It does not copy task/media/helper progress. Control binds it to the mechanically attached exact pair, uses it to prevent slot-reuse inheritance and a second grant at the same boundary, then clears it atomically with the transition out of INTERMISSION after completion/cancellation.

At FORM closure, the existing `server_queue` creates a cancellation-visible `admission_lease`; `server_inference::admission_adapter::plan()` produces one transaction-local exact task-to-slot `placement_plan` and retains its reservations; speculative/cache owners report non-mutating capability and resident/cache facts for the complete control-supplied scope; `inference::admission` returns one `formation_assessment`; and control emits an `admission_commit` binding that exact lease, accepted set, placement plan and assessment before attachment or cache restore. `server_inference::admission_adapter::apply()` applies that same plan once and reports exact `stream_key` values without mutating speculative/cache state. Control combines them with held incumbents and refreshes the complete passive snapshot. If `R > X`, lifecycle/task blockers are empty, decode-family pending work is zero, and the assessment is compatible, control allocates `next_cohort_id++` and atomically freezes identity, ordered membership, profiles and cursor. Only then does `server_execution::executor` apply the committed profile/cache initialization. At or below the exit threshold, control allocates no cohort ID and emits NORMAL initialization. Ordinary NORMAL admission, entry drain, and aborted leases allocate no cohort ID.

Cancellation or completion shrinks `active_cohort::members` without changing its ID while the cohort remains above its exit threshold. Reaching the lower threshold ends and clears the lifecycle; it does not mutate or reuse the ID. A reused physical slot can only enter a later cohort as a new exact pair under a new cohort ID. `max(task_id)` is not a cohort identity because cancellation changes the live maximum, deferred tasks may be older, and synthetic tasks consume task IDs.

Member order is initial mechanical attachment order. Pruning uses stable erase. Cursor normalization is exact: removal before it decrements it; removal at it leaves that index naming the next survivor; empty membership resets it to zero. When grants exist, the committed cursor advances to the successor of the first member actually granted, so the batch starting member rotates even when every member receives a grant. With no grant it retains the normalized supplied cursor. Reconciliation, preparation, retry and execution outcomes never advance it; only the later control commit does. It is never a decode/speculative fairness cursor.

`COHORT_ENTRY_DRAIN` does not add a `pending_cohort` membership catalogue. While inference admission is closed, control derives the complete exact live incumbent set from the refreshed passive snapshot at each boundary and asks admission to assess that supplied scope. Persistent exact membership begins only when FORM atomically creates `active_cohort`; this avoids duplicating slot/task lifecycle or formation-compatibility authority.

## Accepted stream threshold and exit policy

The controller uses configured thresholds, not fixed stream-count constants:

```text
E = entry_streams
X = exit_streams, with 0 < X < E
R = count(independently_runnable_text && cohort_capable)
```

- `R >= E` creates entry intent only. If any exact-scope decode-family work exists, control enters `COHORT_ENTRY_DRAIN`; if none exists, it may proceed directly to FORM. Neither path creates `active_cohort` before FORM commits a compatible uniform prompt-family scope.
- A decode-side `COHORT_ENTRY_DRAIN`/DECODE phase reaching `R <= X` enters INTERMISSION after the complete `iteration_completion` and refreshed passive snapshot, before the next preparation or `target_batch_commit`. A PREFILL-side drop to `R <= X` returns directly to NORMAL because multimodal priority is decode-boundary-only.
- Between the two thresholds, current mode is retained: NORMAL stays NORMAL below `E`, while an active cohort stays active above `X`.
- Control derives `independently_runnable_text`, `cohort_capable` and lifecycle/task-kind blockers from passive current-task lifecycle, task-kind, dependency, aLoRA, capability and policy-held facts; no adapter-published boolean or single `SLOT_STATE_*` value defines them. Queue-owned tasks and dependency-blocked `WAIT_OTHER` children are not independently runnable. Multimodal, embedding, rerank and aLoRA are not cohort-capable; active aLoRA/multimodal and unreviewed model mutations block formation. Mixed signatures or lack of one homogeneous speculative profile make admission's complete-scope `formation_assessment` incompatible; neither control nor admission may silently select a largest compatible subset. `R` is always derived from the complete exact scope.
- For `n_cmpl > 1`, child streams begin counting only after shared-prompt state copying changes them from `WAIT_OTHER` into independently runnable completions. A single request may therefore trigger entry, but request count is never the threshold unit.
- Exiting clears only controller-owned cohort lifecycle state. Surviving slot, sampled-token, speculative, checkpoint, cache and replay state returns to NORMAL. Any MTP-OFF survivor whose target context advanced through prefill or decode without matching MTP capture remains OFF because current mechanics cannot reconstruct its missing draft history; a survivor with no target work may be reconsidered normally.
- A surviving exact stream may later be frozen into another cohort with a new monotonic cohort ID.

The observed stream behavior is parameterized. With example `E = 3`, a third compatible prompt joins two current prompt streams before the next target batch and all three enter the prefill barrier. For two decoders plus one held prompt, threshold crossing creates `COHORT_ENTRY_DRAIN`, not a cohort: every decoder continues until completion/cancellation or the configured lower boundary while the prompt is held. Example `X = 1` reaches that boundary after both decoders drain, while example `X = 2` reaches it after the first. With no ready multimodal task, the zero-work intermission yields the configured NORMAL/formation decision immediately; otherwise the one selected multimodal task runs first. The configured `X` deliberately selects the exit point; no controller branch contains any of these example values.

## Accepted multimodal intermission policy

Multimodal priority is task-scoped and decode-boundary-only:

- An already attached/running multimodal task prevents cohort entry. Control closes competing inference admission and gives it exclusive target execution in NORMAL until task completion/cancellation; it is not drained inside cohort policy.
- A multimodal arrival during `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE remains queue-owned and cannot interrupt or share target execution with cohort work.
- A completed or partially drained concurrent decode set reaching `R <= X` transitions to `COHORT_INTERMISSION` before FORM/PREFILL or NORMAL mixed scheduling.
- At most one oldest ready, mechanically placeable multimodal task receives that boundary grant. `inference::control` commits the class priority; `server_queue` retains storage, cancellation visibility and order among eligible multimodal tasks.
- The selected exact `stream_key` owns target execution until it completes/cancels. Its ordinary text/decode work uses single-stream target manifests. Its media work uses task-scoped `external_target_commit` commands.
- `server_slot::process_mtmd_chunk()` and `mtmd_helper_decode_image_chunk()` at `server-context.cpp:945-1032`, called for consecutive media runs at `server-context.cpp:4174-4205`, retain their internal chunk aggregation, encoding, batch sizing and target calls. Those helper-internal rows/batches are not exposed to control.
- Partially drained text survivors remain attached and held with no preparation, verification or target rows during intermission.
- Completion/cancellation of the selected task ends the intermission even if another multimodal task is queued. A surviving held decoder forces return to NORMAL for mixed scheduling. With no decoder survivor, control opens FORM if a prompt cohort can be formed; otherwise it returns to NORMAL. If no multimodal task was ready, INTERMISSION is the same zero-work decision.
- No freshly drafted unexecuted block crosses the boundary. A replay block created by the completing target manifest remains slot-owned, is held unchanged through INTERMISSION, and is mandatory in the first subsequent NORMAL prefix. MTP-OFF survivors that have decoded remain OFF; later NORMAL policy resumes for newly admitted or otherwise mechanically eligible work.

The exact task is the persistent priority unit, but target authorization remains per controller action. There is no executor-owned open-ended permission and no duplicate media scheduler.

## Accepted speculative-preparation policy

Speculative preparation uses worst-case selection before drafting:

```text
verification_rows_max = 1 sampled row + effective maximum eligible draft rows
```

- `common_speculative_n_max()` at `common/speculative.cpp:2780-2813` provides the maximum across enabled implementations; member eligibility and scheduler caps refine it per stream.
- Draft-model/MTP currently defaults to `n_max=3`, so an MTP-IMMEDIATE cohort reserves at most 4 target rows per stream and 32 for eight streams. MTP-OFF reserves no MTP rows.
- ngram-mod currently defaults to `n_max=64`, `n_min=48`, reserving at most 65 target rows per stream and 520 for eight streams.
- Ngram map variants default `size_m=48`, and the ngram cache bound is 8; neither substitutes for the ngram-mod proposal maximum in row accounting.
- At `n_batch=32768`, eight maximum ngram blocks leave 32248 NORMAL prompt rows. The 32764-row prompt figure belongs to one four-row MTP block, not to ngram or eight MTP streams.
- MTP-OFF cohorts, including LoRA-active cohorts, may still reserve large ngram blocks.
- Dynamic speculation reserves the maximum of every implementation eligible for that member, then reports actual output.
- `inference::batching` selects a fair member set whose reserved atomic blocks fit logical `n_batch`.
- `inference::control` commits that exact preparation set.
- `server_execution::executor` bulk-drafts exactly those selected sequences using the existing speculative operation.
- Existing replay blocks are already-prepared mandatory work: place their known actual rows in the verification prefix before selecting fresh drafting members, and do not bulk-draft them again.
- Every newly drafted block returns as a tagged `prepared_decode_outcome` bound to the selected stream and appears in the same iteration's `target_manifest`; there is no new prepared-but-unscheduled carry-over lifecycle. Existing replay remains the intentional slot-owned carry-over created by a prior verification outcome.
- Actual draft lengths may be shorter than reserved.
- In NORMAL, actual unused decode capacity may become prompt grants after drafting; it may not trigger opportunistic preparation of another speculative member.
- In COHORT_DECODE, prompts remain forbidden and unused logical capacity remains unused.
- `n_ubatch` is physical capacity and never participates in reservation or member selection.
- Verification blocks are atomic across batch views and retries. With current `post_decode()` behavior, the complete prepared verification-row union must remain in the first processed retry view, not merely each block in some view.
- `prompt_cursor` applies only to contiguous prompt grants. Cohort decode/speculative participation never reuses it; no speculative-implementation or lane cursor is introduced.

Capacity pressure preserves decoder participation before dropping members:

```text
residual_after_replay   = logical_capacity - mandatory_replay_rows
uncappable_floor(member) = 1 sampled row
                            + max(effectively allowed MTP maximum,
                                  effectively allowed other-family maximum,
                                  0)
ngram_envelope(member)   = max(uncappable_floor(member), 1 + configured_ngram_max)
```

Mandatory replay blocks reserve the prefix first. In require-all cohort mode, the sum of fresh-member floors must fit the residual or the proposal is explicitly infeasible with no selected partial set. Max-min water filling then increments the lowest current total allowance toward each member's ngram envelope; stable supplied order breaks ties and remainder assignment. Derive each ngram cap from its final allowance. NORMAL may skip non-fitting fresh members in its caller-supplied fairness order while retaining the mandatory replay prefix.

If ngram is allowed and the allocated cap is below configured `n_min`, use literal sampled-token-only decoding for that member/cycle: exactly one logical row and no MTP, ngram or other-family drafting. This is not merely an ngram disable. The per-sequence draft-parameter path must be verified to honor this cap/fallback during implementation. With no replay prefix, `n_batch=32768` and eight ordinary fresh streams, no ngram cap is needed.

That sampled-only fallback is new controller policy, not a claim about legacy
NORMAL behavior. The Phase 0 baseline distinguishes ngram-mod's raw zero-or-
`[n_min,n_max]` result from legacy `common_speculative_draft()` truncation to
the server-derived per-stream `dp.n_max`; the latter can leave `1..47` final
ngram proposals at current defaults near context or output-budget limits.

Preparing a draft couples the sampled token, `spec_draft`, checkpoint, draft implementation/context, verification membership and replay relationship. Avoiding unscheduled prepared work avoids freezing that lifecycle across cancellation, demotion, MTP activation, fairness and phase changes.

## Decisions still requiring consultation

These are design choices, not established source facts:

1. Oversized/reduced retry capacity: RESOLVED. If the complete verification prefix cannot fit effective retry capacity, execution returns a typed `verification_prefix_unfit` result and takes the existing terminal cleanup/error path. Execution never slices, drops, despeculates, restores, or replans during this refactor. Phase 3 transfers the unfit decision from legacy authority to control, where control can later commit explicit restoration/abort and replacement work.
2. Slot/cache mutation classification: RESOLVED. IMMEDIATE = {cancellation signalling, metrics, /health, /slots GET, /lora-adapters GET, NEXT_RESPONSE, shutdown signal, reasoning_end (sampler-local)}. BOUNDARY-GATED = {SET_LORA, prompt-cache save/load, /slots save/restore/erase, slot release/purge/context-shift, speculative policy, deferred-MTP backfill, sleep-state model destroy/reload, decode-failure sweep} at boundary {end-of-iteration (existing queue loop provides this); controller phase transition for sleep/global adapter policy; explicit stop/restart for decode-failure}. The live-slot-release half of cancellation and /slots file ops already enforce idle/defer guards. No generic non-inference bypass exists.
3. Incumbent embedding/rerank work: RESOLVED. Cohort mode requires a pure inference server. If the server is started with --embedding or --reranking, cohort capability is disabled at startup; the cohort phase machine never engages and embedding/rerank tasks always run in NORMAL. No drain-window or intermission policy for embedding/rerank is needed.

The public feature remains unavailable until these decisions and the final review gates are resolved.

## Initial refactor scope boundary

This is an authority and durability refactor, not a speculative post-processing redesign.

Current speculative verification mechanics require the complete sampled/speculative verification union to remain together through server retry processing.

- Preserve the complete sampled/speculative verification union as one indivisible logical prefix for server retry views.
- Retry may reduce or split only the prompt tail.
- Preserve current `common_speculative_process()`, `common_sampler_sample_and_accept_n()`, NextN, output/logit and `post_decode()` ownership/indexing mechanics.
- Keep physical `n_ubatch` microbatching unrelated and unchanged.
- If the complete prefix cannot fit effective retry capacity, report the reviewed explicit outcome and follow only its controller-owned authority path; execution never silently slices, drops, despeculates or replaces work.

## Workstream ownership split

The implementation is divided by source authority, not by arbitrary task size.

### Server workstream

Owns `tools/server/**`, including the server-local `inference::control`,
`inference::admission`, and `inference::batching` policy components;
the existing `server_queue` type; `server_inference`; `server_execution`; slot/task translation;
target-manifest construction; multimodal authorization; server tests; server-facing
observability; and documentation of the server options.

### Non-server workstream

Owns only required changes outside `tools/server/**`. In this plan that is the
shared command-line/configuration surface in `common/common.h` and
`common/arg.cpp`, its focused argument tests, and cross-runtime validation.
`common/speculative.*`, sampling, cache/checkpoint implementations,
`llama_decode()`, and backend microbatching receive no implementation changes.

### Canonical nouns and verbs

The implementation and tests use these terms exclusively:

| Term | Meaning |
| --- | --- |
| `stream_key` | Exact `{slot_id, task_id}` identity used across NORMAL and cohort work |
| `iteration_id` | Monotonic snapshot-to-complete-outcome transaction identity |
| Pending work | Derived visible work, not authorization |
| Proposal | Pure admission/batching calculation |
| Commit | Exact command emitted only by control |
| `target_manifest` | Exact logical target rows, owners, offsets and output requirements |
| `target_batch_commit` | Sole authorization to execute a target manifest |
| `server_batch` | Server storage encoding of the target manifest |
| `batch_view` | Mechanical retry/post-processing view, never a new plan |
| `target_batch_outcome` | Complete target-execution payload after all views and mandatory post actions |
| `iteration_completion` | Proof consumed by control after every command/result in one iteration settles; target work is one possible payload |
| `n_batch` / `n_ubatch` | Logical scheduling capacity / physical backend microbatch capacity |

Generic `proposal`, `committed_preparation`, `committed_batch`, `committed_post_actions`, “logical manifest,” and “lineage handle” names are not implementation vocabulary. Sampling, acceptance, rollback, replay creation, parent/child copying, response capture and release/reset are mandatory consequences of `target_batch_commit`, not a second scheduling command.

### Dispatch and dependency rule

`server_context::update_slots()` remains the mechanical event-loop pump. It collects a passive snapshot, calls `inference::control::next_action(...)`, dispatches exact returned commands, collects their outcomes, finishes mandatory mechanics, submits one `iteration_completion`, and refreshes the snapshot. It cannot select members, classify compatibility, advance phase, allocate rows, discover extra work or substitute another command.

Compile-time direction:

```text
identity/profile values
    -> passive snapshot and producer-owned result DTO headers
    -> admission/batching/control contracts
    -> server adapter/executor implementations
    -> server_context driver
```

Runtime flow:

```text
passive snapshot
    -> exact admission/batching proposal
    -> inference::control exact command
    -> server mechanical application
    -> complete iteration-tagged outcome
    -> refreshed passive snapshot
```

The non-server workstream never includes or calls server policy types. Server
policy may consume plain resolved configuration values and existing common
runtime facts. A newly discovered need to change speculative, sampling,
cache/checkpoint, model, or backend mechanics is separate reviewed scope; it is
not absorbed into a server phase.

| Phase | Server workstream | Non-server workstream | Join condition |
| --- | --- | --- | --- |
| 0 | Capture server scheduling/target manifests and direct target operations | Capture existing common/runtime outputs without changing them | Baseline fixtures accepted |
| 1 | Add dormant server-local vocabulary and stable leaf-pure proposal calculations | None | Contract and pure-algorithm tests pass; no executable controller exists |
| 2 | Extract mechanical server execution under legacy authority | None | Legacy target manifests remain identical |
| 3 | Transfer NORMAL target-work commit authority | None | Every target invocation has a control commit |
| 4 | Add queue leases and transfer admission authority | None | Cancellation/attachment ownership tests pass |
| 5 | Transfer NORMAL MTP activation timing around existing common mechanics | None | Post-activation facts feed reservation unchanged |
| 6 | Integrate ENTRY_DRAIN/FORM/PREFILL/DECODE/INTERMISSION behind inaccessible thresholds | None | Cohort integration gates pass |
| 7 | Consume resolved options; expose server logs, metrics, props and docs | Add paired option fields/parsing/environment wiring and argument tests | Disabled and enabled configuration paths agree |
| 8 | Server regression, workload and authority-residue validation | Common-argument regression plus unchanged-runtime and ROCm validation | Production decision uses combined evidence |

## Phase 0 — Baseline fixtures and review freeze

Source commit: one dedicated documentation/fixture commit. It freezes the two
reviewed architecture documents together with
`COHORT_BATCHING_PHASE0_NORMAL_BASELINE.md` and
`tests/python/fixtures/cohort_batching_normal_manifest_baseline.json`.
It changes no runtime source or behavior.

### Objective

it does not claim live access to transient reconciled `reconciled_prompt_coverage` facts, a shadow progress projection, or a new `iteration_id`. Live shadow projection of transient reconciled facts begins with the Phase 2 translator unless Phase 0 explicitly authorizes behavior-neutral diagnostic instrumentation.

Target-manifest fixtures record the synthetic legacy turn, unavailable/null
`iteration_id`, exact `stream_key`, declared constituent row kinds,
`maximum_possible_rows`, actual constructed offsets/counts, null legacy
reservation, exact adapter signature, output rows and direct external target
operations for:

- Generation with and without speculation.
- Prompt-only and mixed continuous batching.
- `--no-cont-batching`.
- Base/no-LoRA, identical static LoRA, mixed LoRA signatures and aLoRA boundaries.
- Parent/child completions.
- Cache hit/reuse/checkpoint restore.
- Embedding, rerank and multimodal execution.
- Deferred MTP modes.
- Retry with atomic verification blocks.
- Dynamic/ngram/MTP cases whose actual draft length is below the effective maximum.
- Multi-implementation speculation with the fixed internal implementation
  priority, raw implementation result, server-derived per-stream cap and final
  post-truncation legacy proposal rows recorded separately. Requested type-list
  order is not implementation priority.
- Cancellation immediately before the next inference iteration.
- Fully cached prompt reuse with forced last-token logits evaluation.
- Context shift and replay outcomes demonstrating that physical extent may move while accepted output does not regress.

Relevant regions are `server-context.cpp:138-263`, `2817-3052`, `3392-4701` and `server-queue.cpp:22-221`.

### Server workstream

Capture the authoritative server decisions, target manifests, external target
operations, cancellation points, source mutation regions, and response-visible
outcomes listed above. Annotate which current fields are lifecycle-gated,
prepared/retractable, or physical rather than inventing unavailable runtime
frontier evidence.

### Non-server workstream

Record the existing common speculative, sampling, cache/checkpoint,
`llama_decode()`, and backend outcomes referenced by those target manifests. Change no
non-server source or runtime behavior.

### Gate

The source-annotated baseline catalogue, machine-readable manifest fixtures,
and open decisions are accepted in the dedicated Phase 0 commit. No runtime
authority changes.

## Phase 1 — Component contracts and dormant policy tests

Separately committable: yes; additive and runtime dormant.

### Authority

Runtime authority remains entirely in current server code. Phase 1 introduces no applying or simulated controller. New components contain value vocabulary, passive snapshot/result contracts and stateless leaf-pure proposal calculations only.

### Server workstream

- Add distinct, server-local namespace/file boundaries for value-only `inference::identity` and `inference::profile`, proposal-only `inference::admission` and `inference::batching`, passive `server_inference` snapshots and producer-owned `server_execution` result vocabulary. Add no generic types/facts/utils/scheduler bucket.
- Define strong value types for `identity::stream_key`, `identity::cohort_id`, and `identity::iteration_id`. Phase 1 tests type separation; it does not allocate either monotonic ID in a runtime or simulated state machine.
- Define exact value-based `profile::adapter_signature`, empty base signature, `cohort_mtp_mode { OFF, IMMEDIATE }`, and immutable `cohort_speculative_profile`.
- Define passive `server_inference::stream_snapshot` facts for exact task/slot identity, raw lifecycle, exact source operation identity, input kind, embedding width, dependency, adapter/aLoRA state, speculative capabilities, prompt/output observations and physical runtime observations. COMPLETION and INFILL remain distinct operations even when both use token-sequence input; multimodal remains an input kind. The snapshot contains no preclassified runnable/capable/blocker verdict, `R`, phase or scheduling grant.
Keep only the exact-stream `prompt_reconciliation_result` vocabulary whose local producer and meaning are already known; it carries no iteration, cohort, closure or execution-lineage claim. The full iteration-tagged `prompt_reconciliation_outcome` type begins in Phase 2.
- Record single-producer semantics in types and tests: passive snapshot projection owns lifecycle-gated observations; the reconciliation producer owns its exact-stream result; admission owns complete-scope formation assessment; batching owns compatibility, reservation and row-grant proposals. Phase 1 adds no second derivation or mutable mirror.
- Implement the lifecycle-gated passive projection for the exact current task. Stale reused-slot output/sample fields are ignored outside their legal lifecycle; prepared/retractable and physical facts remain visibly distinct from committed logical facts.
- Keep runtime speculative eligibility/synchronization, immutable cohort allowed profile and effective reservation masks as distinct inputs.
- Implement leaf-pure `admission::assess_formation()` over one caller-supplied trusted, complete, ordered vector of exact stream snapshots. It derives its returned exact ordered keys from that vector and returns the homogeneous adapter signature, homogeneous speculative profile, compatibility and a typed incompatibility reason. It has no parallel key list, missing-member policy, subset selection, `R`, lease, attachment or cohort binding. Effective aLoRA remains a passive fact whose cohort blocker policy belongs to control.
- Implement leaf-pure NORMAL compatibility grouping from exact raw source operation identity, input kind, embedding width, effective aLoRA state and exact ordered adapter signature. COMPLETION and INFILL are distinct grouping values independent of input kind. The calculation returns a proposal only and owns no fairness or admission state.
- Implement leaf-pure worst-case decode pricing/selection from logical `n_batch`, effective implementation masks, frozen allowed speculative profile and implementation maxima. Preserve replay-prefix cost; asymmetric per-member uncappable floors; require-all exact-fit/infeasible behavior; max-min total-allocation water filling with stable supplied-order ties; maximum-across-eligible-implementations accounting; derived ngram caps; literal one-row sampled-only fallback below `n_min`; and an explicit all-or-nothing infeasible result with no selectable partial set. NORMAL may skip non-fitting fresh candidates only in its supplied fairness order.
- Implement leaf-pure contiguous prompt-grant/cursor proposal calculation from stable ordered candidates and a supplied cursor. A non-empty proposal advances past the first member actually granted; an empty proposal retains the normalized supplied cursor. Phase 1 does not store, prune or commit that cursor.
- Define only already-stable control values: `phase`, resolved paired-threshold `config`, and immutable `active_cohort` shape. Phase 1 defines no command names/shapes, `controller`, `control_state`, `evaluate_boundary()`, cohort binding, intermission quota state, iteration stages/closures, target-manifest construction, executor interface or proposal application.
- Do not introduce `server_queue` lease values, queue admission methods, placement plans or `server_inference::admission_adapter` in Phase 1. They land together in Phase 4 so queue ownership, cancellation visibility, reservation retention and one-time application are established atomically.
- Keep all interfaces C++17 and server-local. The Phase 1 target is test-only/dormant and has no source-runtime wiring.

Phase 1 source is limited to `inference-identity.h`, `inference-profile.h`, the value-only `inference-control.h`, `server-inference-snapshot.{h,cpp}`, the result-only `server-execution-outcome.h`, `inference-admission.{h,cpp}`, `inference-batching.{h,cpp}`, and its dormant test/CMake registration. None is listed in `tools/server/CMakeLists.txt` or linked into `llama-server`.

### Non-server workstream

No source changes. Use existing common fact/query interfaces, including
`common_speculative_n_max()`, as immutable inputs to dormant server-local policy
tests.

### Untouched

Existing `server_queue`, live slots, `server_context`, `server_batch`, speculative code, cache/checkpoints, model execution and responses.

### Gate

- No live server source, existing queue declaration or runtime CMake target calls or contains the new components.
- No mutable controller, simulated phase machine, command application, iteration closure, manifest builder, queue lease or admission adapter exists in Phase 1.
- Strong-type and namespace/dependency tests prove task/slot/stream/cohort/iteration identity separation and one-way component dependencies without a monolithic scheduler namespace.
- Passive projection tests prove lifecycle-gated stale-field exclusion and keep committed logical, retractable prepared and physical observations semantically distinct.
- Admission tests prove one trusted ordered snapshot scope derives the returned exact ordered keys, homogeneous adapter/speculative assessment, exact ordered signatures, MTP-OFF fallback, and rejection without largest-compatible-subset selection; aLoRA blocker policy is absent from admission.
- NORMAL compatibility tests cover exact operation identity including COMPLETION versus INFILL, independently from input kind, embedding width, effective aLoRA state and exact adapter signature.
- Reservation tests prove maxima across only effectively allowed implementations, frozen-profile MTP exclusion, ngram/other mask exclusion, replay-prefix pricing, asymmetric uncappable-floor exact fit, max-min fairness with stable ties, per-member ngram caps, combined-family literal one-row fallback below `n_min`, MTP 4-row and ngram-mod 65-row examples, and explicit infeasible all-or-nothing output.
- Prompt tests prove contiguous grants, rotation past the first actual grantee, normalized-cursor retention when no work is granted, and no mutable cursor ownership.
- Accepted phase transitions, exact scopes, thresholds, drain rules, WAIT_OTHER behavior, cohort identity binding and intermission behavior remain architecture truth-table fixtures. They are not executable Phase 1 controller tests; Phase 6 implements and tests them under the runtime authority that owns them.
- The dormant test target and a Release CPU `llama-server` compile pass with no runtime integration.

### Rollback

Revert the additive contract/test commit. No runtime authority or existing queue declaration moved in this phase.

## Phase 2 — Mechanical execution extraction under legacy authority

Separately committable: yes.

### Authority transfer

None. A single legacy planner remains the sole runtime scheduling authority. `server_execution` becomes mechanical.

### Affected code

- `server-context.cpp:3392-3500` (`update_slots`).
- `server-context.cpp:3543-4331` (current `pre_decode`).
- `server-context.cpp:4335-4458` (decode and external execution boundary).
- `server-context.cpp:4460-4701` (post-decode outcomes).
- `server-context.cpp:945-1020` (multimodal direct target execution).

### Server workstream

- Derive the exact runtime correlation contract from the existing legacy turn: monotonic `iteration_id`, prepared/reconciliation lineage, `batch_view`, `server_batch`, `target_manifest`, complete `target_batch_outcome`, `iteration_completion`, and the non-target completion variants. Replace any provisional Phase 1 DTO shape that the real seam disproves.
- Move, rather than copy, existing selection into one temporary legacy intent/target-manifest producer.
- Add `server_inference::snapshot_reader` as the sole passive, history-free translator and a diagnostics-only progress/pending-work comparator. Neither can mutate control, fairness cursors, slots/runtime, the legacy intent, or the finalized target manifest.
- Reshape `server_context::update_slots()` into the mechanical pump contract without transferring runtime authority yet: snapshot, legacy decision, exact dispatch, complete outcome, refreshed snapshot.
- Extract one typed `server_execution::executor` façade from those real seams. Its preparation overloads perform legacy-authorized maintenance/context shift, draft preparation, prompt reconciliation and cache/speculative initialization; its target/external overloads construct exact `server_batch` values, invoke exact-task-scoped multimodal helpers, execute target/spec work, process mechanical retry views and report complete outcomes around existing sampling/replay/release mechanics. The interface is mechanical and does not yet imply a control commit.
- Require the legacy planner to name exact prompt-reconciliation members before any STARTED-state mutation.
Split the current per-slot coupling: reconcile every selected prompt stream mechanically, return exact iteration-tagged `prompt_reconciliation_outcome` values, publish one global snapshot, then let the unchanged legacy authority choose/grant rows. No target work or unrelated scheduling occurs inside that stage.

Staged reconciliation seam contract (no target work, admission sweep, phase transition, fairness advancement, or unrelated scheduling decision between stages):

```text
passive raw slot/task/capability facts
    -> batching proposes exact members requiring reconciliation
    -> control commits prompt-reconciliation membership
    -> server_execution and existing owners reconcile mechanically
    -> tagged reconciled-prompt outcomes are published
    -> server_inference builds one global ephemeral fact snapshot
    -> batching proposes exact prompt grants
    -> control commits the final target batch
```
- A mutably prepared live prompt stream must receive at least one legal grant in the resulting target manifest.
- The legacy intent reserves `1 + effective draft maximum` for each speculative candidate, selects a fitting set, and bulk-prepares only that set.
- The effective maximum comes from every implementation eligible for that member after scheduler caps; it is not hard-coded to MTP `n_max`.
- Every `prepared_decode_outcome` appears in the same iteration's finalized legacy target manifest; do not exercise the existing reuse capability as a scheduler carry-over policy.
- Add target-manifest block offsets, a contiguous verification prefix and retry metadata that preserves the entire prepared union in the first processed view.
- Treat replay blocks as mandatory known-size prefix members before selecting fresh drafts; never draft them again.
- Permit retry to reduce/split only the prompt tail; the complete verification prefix remains indivisible.
- Implement the resolved oversized-prefix outcome: if the complete verification prefix cannot fit effective retry capacity, the executor returns a typed `verification_prefix_unfit` result and takes the existing terminal cleanup/error path. The executor never slices, drops, despeculates, restores, or replans. Phase 3 transfers the unfit decision from legacy authority to control, where control can later commit explicit restoration/abort and replacement work.
- Preserve existing execution order and target-manifest output exactly.
- Accumulate `batch_view` results mechanically, capture exact stream/block/offset identity before release/reset, finish mandatory post actions, publish one complete `target_batch_outcome`, and wrap the settled turn in one `iteration_completion`. Admission-only and zero-work turns use their explicit completion variants.
- Compare projected pending work with the finalized legacy target manifest and complete outcome only. The comparator is shadow evidence, never an applying scheduler.

Temporary seam: `make_legacy_intent()`, staged reconciliation, `finalize_legacy_target_manifest()`, and the non-applying comparator. The legacy planner functions and categorical scheduling interpretation are deleted atomically in Phase 3; snapshot/reconciliation/outcome seams remain.

### Non-server workstream

No source changes. Preserve common speculative preparation/verification,
sampling, cache/checkpoint, `llama_decode()`, and backend behavior byte-for-byte
at their existing call boundaries.

### Untouched

`common/speculative.*`, `llama_decode`, physical microbatching, cache/checkpoint implementations, sampling, verification, rollback, replay, and speculative `post_decode()` view/membership/indexing mechanics.

### Gate

- NORMAL target manifests equal Phase 0 fixtures.
- The extracted identity/lineage/outcome contract is backed by the real legacy producer and executor boundary rather than a simulated Phase 1 controller.
- The translator/comparator cannot affect membership, grants, preparation, fairness, phase, admission or runtime state.
- Reconciliation is complete for every named member before the global fact snapshot and legacy grants.
- Projected pending work explains every finalized legacy row, and every row maps to one pending-work item or exact external operation.
- No projection is published while an iteration is incomplete, including preparation in flight or between `batch_view` values.
- The executor cannot discover an unlisted stream or select a command category.
- Multimodal helper execution requires the temporary legacy scoped authorization.
- Prompt preparation cannot mutate an uncommitted candidate.
- Retry keeps the complete prepared verification prefix in its first processed view.
- Retry tests keep that complete prefix intact and partition only the prompt tail.
- A prefix that cannot fit effective retry capacity returns a typed `verification_prefix_unfit` result and follows the existing terminal cleanup/error path; the executor never slices, drops, despeculates, restores, or replans it.
- Retry treats a 65-row maximum ngram block as one atomic unit.
- A prepared speculative stream is never omitted from its iteration's target manifest.
- Output/logit and NextN rows match target-manifest block membership.

### Rollback

Revert Phase 2 while Phase 1 remains dormant.

## Phase 3 — Control takes sole NORMAL target-work authority

Separately committable: yes.

### Authority transfer

`inference::batching` calculates exact NORMAL preparation and target-batch proposals. `inference::control` becomes the sole emitter of target-work commands, including scoped multimodal execution. `server_execution` applies them mechanically.

Admission and MTP activation timing remain in their existing single owners during this phase; the new control API does not claim those decisions yet.

### Server workstream

- Implement the first mutable `inference::control::controller` and iteration protocol for NORMAL target transactions only. It consumes the Phase 2 settled snapshot/outcome boundary, commits exactly one command lineage per turn, constructs `target_manifest` only from matching preparation/reconciliation outcomes, and accepts only the matching complete closure.
- Store only NORMAL transaction state required to correlate the active iteration, issued preparation/reconciliation commands and expected completion. Do not implement cohort phase transitions, cohort binding, entry drain, intermission quota or FORM state in this phase.
- Use the Phase 2 `server_inference::snapshot_reader` without host-side cohort classification.
- Translate passive exact-stream lifecycle/dependency/task-kind/capability facts mechanically; control alone owns runnable/capable/lifecycle-blocker classification, exact scope and `R`. Admission remains the sole formation-compatibility calculator when cohort policy becomes reachable.
- Group NORMAL work mechanically by task/input compatibility and exact adapter signature, including effective aLoRA state.
- Derive phase-neutral pending work from the lifecycle-gated progress projection, then calculate NORMAL generation-first and continuous-batching proposals without storing that projection.
- While legacy code still owns activation timing, require its NORMAL activation scan/outcomes to complete first, then translate refreshed eligible masks and maxima into the Phase 3 reservation facts.
- Reserve worst-case verification capacity and emit `decode_preparation_commit` for the exact fitting decode set before draft mutation.
- Bulk-draft exactly the selected set and return exact iteration-tagged `prepared_decode_outcome` values; never reselect from those outcomes.
- From actual residual logical capacity, calculate `prompt_reconciliation_proposal` and emit the exact corresponding command without adding another speculative stream.
- Reconcile those streams mechanically, publish one global tagged snapshot, then calculate contiguous prompt grants.
- Calculate `target_batch_proposal` from actual preparation/reconciliation outcomes and have control emit `target_batch_commit` naming every exact row. Only that command authorizes target execution.
- Emit `external_target_commit` for the exact multimodal task before direct helper execution; do not expose or independently schedule its internal media chunks/batches.
- Accumulate `batch_view` results, capture exact identity before release/reset, finish mandatory post actions, and report one complete `target_batch_outcome` without advancing policy in `server_execution`.
- Delete both temporary legacy planner functions, the shadow comparator, and every legacy target-scheduling interpretation in the same commit:
  - generating membership/speculative selection (`tools/server/server-context.cpp:3629-3745`, deleted at Phase 3 takeover);
  - prompt membership, compatibility-group selection and grants (`tools/server/server-context.cpp:3754-4292`, deleted at Phase 3 takeover);
  - context-shift/maintenance authorization selected from generating state (`tools/server/server-context.cpp:3546-3612`, deleted at Phase 3 takeover).
Retain `SLOT_STATE_*` only for mechanical current-task translation and response/outcome lifecycle. The sole temporary exceptions are the two isolated legacy NORMAL MTP activation timings (`tools/server/server-context.cpp:3614-3618` pre_decode maintenance pass and `4512-4518` post_decode prompt-completion transition), isolated behind their explicit fact/outcome seam until Phase 5 removes both atomically. The temporary exception

### Non-server workstream

No source changes. Existing common runtime calls remain mechanical operations
invoked only after the new server control commit.

### Gate

- Every target invocation has a control commit.
- The NORMAL controller rejects a command outside its active iteration, duplicate commands, wrong tagged outcomes, partial/wrong closures and target construction from caller-invented rows.
- No legacy planner, shadow comparator or categorical target-scheduling interpretation remains.
- Outside the mechanical translator/outcome paths and the isolated Phase 5 MTP-timing exception, no `SLOT_STATE_*` branch selects members, grants, preparation or maintenance.
- Every NORMAL turn uses one monotonic `iteration_id` with distinct preparation commands and one `target_batch_commit`; only the latter reaches target execution.
Explicit Phase 3/4 delete-list gate: Phase 3 deletes the exact legacy authority catalogue — generating selection/speculative preparation `tools/server/server-context.cpp:3629-3745`, prompt membership/compatibility/reconciliation/grants `3754-4292`, and context-shift maintenance `3546-3612`. The sole surviving legacy scheduling exception during Phases 3-4 is NORMAL MTP activation timing
(`try_activate_deferred_mtp` plus its two call sites and their `SLOT_STATE_GENERATING`/`SLOT_MTP_PREFILL_DEFERRED` predicates), with the two temporary MTP exceptions at `3614-3618` and `4512-4518`. Verification: `rg -n "SLOT_STATE_(GENERATING|DONE_PROMPT)" tools/server/server-context.cpp` must show no scheduling-selection branch outside `server_execution` and the isolated MTP-timing exception, so the exception cannot silently widen.
- Mechanical deletion-commit verification: after Phase 3, no `SLOT_STATE_GENERATING`/`SLOT_STATE_DONE_PROMPT` branch may reach `try_activate_deferred_mtp`, `batch.add`, or `spec_draft` outside `server_execution`.
- Reconciliation for the complete selected set precedes the global fact snapshot and grant proposal.
- No phase, admission, fairness or next-work decision consumes a partial batch-view outcome.
- Threshold remains disabled and NORMAL target manifests match the baseline.
- `n_ubatch` is absent from admission/batching/control inputs.
- Reserved block totals never exceed `n_batch`; actual shorter blocks may only expand NORMAL prompt grants.
- At `n_batch=32768`, eight maximum ngram blocks reserve 520 rows and leave 32248 prompt rows; eight maximum MTP blocks reserve 32.
- Dynamic selection reserves its maximum eligible implementation rather than the implementation ultimately returning the shorter draft.
- Phase 3 reservation always consumes facts refreshed after the legacy NORMAL activation outcome; it never reserves from the member's pre-activation mask.
- Server translation provides passive lifecycle, dependency, adapter/input properties and capability facts, not a formation verdict, scheduling classification, pending-work decision or `R`.

### Rollback

Revert Phase 3 to the Phase 2 legacy seam. After later phases land, rollback must proceed in reverse order first; see `docs/archive/COHORT_ROLLBACK_RUNBOOK.md` for the mandatory per-phase reverse-order steps and verification commands.

## Phase 4 — Queue leases and atomic admission authority

Separately committable: yes.

### Authority transfer

The existing `server_queue` remains the sole task-order/storage/cancellation owner and gains nested lease values rather than a conflicting namespace. `inference::admission` proposes from leased candidates and one exact placement plan. `inference::control` becomes the sole admission-window and accepted-plan committer. One `server_inference::admission_adapter` plans the transaction and applies that same committed exact plan once.

The progress/pending-work delta adds no separate admission authority and stores no admission-time progress projection. Phase 4's accepted-set/window takeover remains exactly as defined here.

### Affected code

- `server-queue.h/.cpp:22-100`, `125-221`.
- Release callback at `server-context.cpp:1656-1668`.
- Slot placement at `server-context.cpp:1908-2288`.
- Admission at `server-context.cpp:2817-3052`.
- Queue/update wiring at `server-context.cpp:1755-1764`, `3392-3500`.
- `server-speculative-policy.*` invocation boundary.

### Transaction

```text
queue-owned cancellation-visible lease
    -> reservation-aware exact task-to-slot placement_plan
    -> exact-scope speculative plus resident/cache capability facts
    -> inference::admission::admission_proposal + formation_assessment
    -> inference::control::admission_commit binding lease + accepted set + placement + assessment
    -> minimal slot attachment in queue order: cancellation ownership cutover
    -> exact stream_key reporting
    -> FORM active-cohort bind or NORMAL-initialization commit
    -> server_execution mechanical speculative/cache initialization
    -> queue lease resolution
```

The FORM bind branch is a dormant contract in Phase 4 and becomes reachable only in Phase 6; NORMAL uses the same ownership/initialization seam immediately.

### Server workstream

- Add nested `lease_id`, `leased_candidate`, and `admission_lease` values inside the existing global `server_queue` ownership domain; do not add a `server_queue` namespace.
- Add the queue-owned lease values, `placement_plan`, one `server_inference::admission_adapter` `plan()`/`apply()` contract, admission command/outcome lineage and controller admission-transaction state atomically in this phase; none are predeclared as an applying API in Phase 1.
- Make `post(CANCEL)` invalidate queued, deferred or leased candidates.
- Restore unaccepted leases in exact relative order.
- Implement `server_inference::admission_adapter::plan()` to produce one transaction-local exact task-to-slot `placement_plan` and retain its reservations; implement `apply()` to consume that same committed plan without calling slot selection again.
- Preserve parent/child all-or-none placement.
- Remove direct inference promotion from slot release.
- Reconcile released exact streams from passive snapshots; do not add a release-event queue.
- Route every immediate continuation through a fresh queue/control sweep before model work.
- Calculate speculative capability and resident/cache facts once over control's complete exact scope before the admission proposal, without taking a cache entry or mutating a reserved slot. Admission alone calculates the scope's `formation_assessment`; control commits or rejects it without recalculation. Commit the FORM profile before attachment; apply only the selected post-attachment cohort or NORMAL initialization before cache restore and target work.
- Preserve exact ordered adapter-set/scale facts through admission. Do not identify signatures by hash alone.
- Keep queue `lease_id` in `server_queue`; neither NORMAL admission nor an aborted lease allocates or supplies a `cohort_id`.
- Have `server_inference::admission_adapter::apply()` attach and `snapshot_reader` return exact `stream_key` values mechanically. Only control can bind them into an `active_cohort`.
- Refresh passive exact identity/liveness/dependency facts after attachment, cancellation, release and slot reuse. A new `stream_key` inherits no progress/pending-work projection from the previous task.
Treat parent/child activation as a later execution outcome after mechanical state copying, not as an admission decision; publish refreshed facts only after the complete-manifest closure produces the complete `target_batch_outcome`.
- Support a controller-committed ordered predicate for the oldest ready multimodal task without moving it into a second queue; later INTERMISSION integration binds the attached exact pair as `intermission_task`.

### Non-server workstream

No source changes. Prompt-cache and speculative owners expose their existing
non-mutating capability, synchronization and restore-mode facts; the server remains responsible for admission
policy, attachment, and committed initialization ordering.

### Gate

- No host-local second candidate queue exists.
- The admission controller accepts only the boundary-selected queue lease/candidate set and the adapter applies the exact retained placement plan once; no Phase 1 placeholder can bypass or duplicate this authority.
- Mechanical attachment of an exact pair is the queue-to-slot cancellation ownership cutover. Before attachment, the cancellation-visible lease invalidates a candidate even after control acceptance. After attachment, cancellation is slot-owned; an attached-then-cancelled pair is reported released and excluded before FORM/INTERMISSION binding, or reconciled before the next target authorization if already bound.
- Queue order and requested-slot/cache-affinity/LRU placement remain mechanically defined.
- Completion/infill tasks attach only inside committed admission transactions.
- Slot release never promotes inference directly.
- Lease, task, slot, `stream_key`, `cohort_id`, and `iteration_id` remain distinct in transaction records.
- No admission transaction creates or stores a member progress/pending-work mirror, and slot reuse publishes facts only for the new exact task.
- Multimodal priority changes which queue-owned candidate control accepts, not queue storage/order or `admission_adapter` placement mechanics.

### Rollback

Revert Phase 4 before reverting Phase 3.

## Phase 5 — NORMAL MTP activation and completion sequencing authority

Separately committable: yes.

### Authority transfer

Speculative policy remains the eligibility authority. `inference::control` becomes the sole activation-timing committer while preserving current NORMAL behavior. Speculative runtime remains the capture/backfill/begin/draft/verification/replay mechanic. Cohort mode is still inaccessible and adds no activation behavior in this phase.

### Affected code

- Admission/spec mode at `server-context.cpp:2876-3026`.
- `try_activate_deferred_mtp()` at `server-context.cpp:3502-3541`.
Legacy independent activation sites at `server-context.cpp:3614-3618` (pre_decode maintenance pass) and `4512-4518` (post_decode prompt-completion transition), both deleted in this phase. The pre-landed post_decode generating-scan edit already in the working tree must be re-verified against this final Phase 5 design before Phase 5 lands.
- `server-speculative-policy.*`.

### Server workstream

- Convert `try_activate_deferred_mtp` into a mechanical NORMAL activation operation with no independent permission decision.
- Report current NORMAL eligibility/occupancy facts from existing speculative policy.
- Have batching calculate `mtp_activation_proposal` and control emit `mtp_activation_commit` for the same NORMAL set/order as the current scans, but at the single canonical post_decode generating-scan boundary instead of the legacy pre_decode/prompt-completion timing.
- Replace both independent activation decisions atomically with exact activation commands invoking the mechanical operation; do not change NORMAL archive or active-limit semantics. Delete both legacy call sites: the pre_decode maintenance pass at `server-context.cpp:3614-3618` and the post_decode prompt-completion transition at `server-context.cpp:4512-4518`.
- After mechanical activation attempts, report outcomes and refresh eligible masks/maxima before invoking the Phase 3 reservation path. The single post_decode generating scan therefore runs after verification/sampling/post-decode outcomes complete and after any slot releases in that iteration, but before the next iteration's prompt-reservation and debt pricing.
- Keep runtime eligibility/synchronization, the immutable cohort profile and the post-activation effective reservation input distinct. Activation changes runtime facts and row price, not committed logical progress.
- Preserve activation-before-`common_speculative_begin()` at NORMAL prompt completion: after a successful activation commit and mechanical backfill in server_execution, `common_speculative_begin()` is invoked exactly once at the same post_decode boundary. The legacy pre_decode activation skipped `common_speculative_begin()`; the unified generating scan fixes that defect. A later valid first activation from a completed prompt archive uses the existing backfill path without beginning the sequence again.
- Add no cohort activation, archive, cursor, or scan path in this phase.
- Specify both NORMAL activation paths:

```text
generating scan (post_decode boundary, periodic):
    raw/runtime facts (after verification/sampling, after slot releases)
        -> batching activation proposal
        -> control activation commit
        -> mechanical activation attempt (backfill in server_execution)
        -> common_speculative_begin exactly once per newly activated stream
        -> refreshed masks/maxima
        -> pending-work pricing and reservation (next iteration)

prompt completion (post_decode, via the generating scan):
    prompt target outcome
        -> control activation commit
        -> mechanical activation attempt (backfill)
        -> common_speculative_begin exactly once
        -> sampling/client outcome
        -> complete target_batch_outcome progress refresh
        -> next iteration_id
```

The two NORMAL activation paths above are explicit: the periodic generating-scan path runs facts -> control activation commit -> mechanical attempt -> refreshed runtime masks/maxima -> debt pricing/reservation; the prompt-completion path runs prompt target outcome -> control activation commit -> mechanical activation -> `common_speculative_begin()` exactly once -> sampling/client outcome -> quiescent progress refresh -> next iteration lineage. Debt never decides MTP eligibility or activation timing.

The generating scan is periodic: it re-checks DEFERRED slots on every post_decode boundary
- Capture-memory bound: finalize, or otherwise bound, a DEFERRED slot's hidden-state capture at the post_decode boundary after the prompt-completion transition and/or before each backfill attempt; capture must not remain active across an unbounded number of target-only decode iterations. This matches the capture lifecycle in `MTP_DEFERRED_PREFILL_IMPLEMENTATION_PLAN.md`, where prompt completion finalizes coverage and cancellation/lineage mutation finalize or discard capture rather than letting it grow without bound.
- Deletion catalogue: legacy call site 1 (`tools/server/server-context.cpp:3614-3618`, pre_decode maintenance pass) and legacy call site 2 (`tools/server/server-context.cpp:4512-4518`, post_decode prompt-completion transition) are both deleted in Phase 5 and replaced by the single post_decode generating scan owned by control. Mechanical backfill remains in server_execution.
- Preserve NORMAL archive/capture/retry state across the authority transfer.
- Keep ngram/dynamic selection, NextN, draft algorithms, acceptance, rollback and replay unchanged.
- Preserve output/logit reservation and per-sequence limits for the exact committed block membership.
- Verify per-sequence ngram draft parameters accept the committed scheduler cap and sampled-only fallback.

### Non-server workstream

No source changes. `common_speculative_begin()`, activation/backfill mechanics,
drafting, NextN extraction, verification, rollback, and replay retain their
existing contracts and state ownership.

### Gate

- Only a control commit can call deferred activation.
- Existing speculative policy determines eligibility without phase authority.
- NORMAL activation-set order, post_decode generating-scan timing, active-limit decisions, archive outcomes and speculative regression remain unchanged.
- Every NORMAL reservation observes post-activation outcome facts; no successful same-iteration activation can add unreserved verification rows.
- Pending-work derivation never decides MTP eligibility or activation timing, and no prompt-completion progress fact is published before begin/sampling and the complete `target_batch_outcome`.
- Both former independent activation decisions are absent; there is no fallback scan. Only the post_decode generating scan re-evaluates DEFERRED slots, and `common_speculative_begin()` runs exactly once per successfully activated stream at that same boundary.
- Mechanical deletion-commit verification: after Phase 5, zero runtime references to the two deleted legacy MTP activation call sites remain (grep-verifiable). `rg -n "try_activate_deferred_mtp" tools/server/server-context.cpp` must show only the mechanical NORMAL activation operation invoked under a control commit, with no pre_decode maintenance-pass call site and no post_decode prompt-completion-transition call site.
### Rollback

Revert Phase 5 before Phase 4 or Phase 3; see `docs/archive/COHORT_ROLLBACK_RUNBOOK.md` for the mandatory per-phase reverse-order steps and verification commands.

## Phase 6 — Cohort runtime integration behind inaccessible paired thresholds

Separately committable: yes.

### Authority transfer

The NORMAL target/admission controller already owns its Phase 3/4 transactions. Phase 6 adds the executable cohort phase policy and makes control the sole owner of `COHORT_ENTRY_DRAIN`, INTERMISSION, FORM, PREFILL and DECODE transitions. This is the first phase containing mutable cohort lifecycle state, threshold/hysteresis decisions, cohort binding or intermission quota state.

### Server workstream

- Extend control with the single mutable cohort phase machine, monotonic cohort allocation, immutable `active_cohort`, stable prompt cursor and exact intermission-task grant. Phase 1 phase/config/cohort declarations become runtime state only here.
- Implement and test the accepted architecture truth table here: complete-scope classification, `WAIT_OTHER` exclusion/liveness, configured `E`/`X` hysteresis, decoder-free FORM rule, uniform entry drain, active-member-only PREFILL/DECODE, lower-boundary release, exact one-task intermission and stable cursor pruning/advancement.
- After one complete NORMAL `iteration_completion`, have control derive `independently_runnable_text`, `cohort_capable`, lifecycle/task blockers, the complete exact entry scope and `R` from the refreshed passive snapshot. Threshold crossing records entry intent only; it never allocates a cohort ID or creates `active_cohort`.
- Have control submit that complete exact scope to `inference::admission` for the sole adapter/speculative `formation_assessment`, then commit or reject the result without recalculating compatibility or selecting a subset.
- If an attached multimodal task is live, remain NORMAL and authorize only that exact task until it completes/cancels; re-evaluate cohort entry afterward.
- Permit FORM only when admission reports one exact static adapter signature and one homogeneous speculative profile for the complete proposed member set; never select the largest compatible subset.
- Treat base/no-LoRA as the empty signature.
- Keep mixed active signatures in NORMAL until the conflicting work clears.
- Exclude aLoRA from cohort membership and treat active aLoRA as a formation blocker.
- If any attached cohort-capable incumbent has decode-family pending work when `R >= E`, enter `COHORT_ENTRY_DRAIN`, close ordinary inference admission, derive every exact live incumbent from each refreshed post-completion snapshot, and create no shadow drain membership, active cohort, provisional cohort ID, or event-maintained `R` state.
Define `decode_family_pending` as mandatory replay, pending sampled-token evaluation, or fresh speculative verification work. Define `prompt_family_pending` as unresolved prompt reconciliation, remaining prompt tokens, or mandatory last-token/logit evaluation. These derived debt predicates replace any categorical `SLOT_STATE_*` phase predicate; they are not per-slot phase state.
- In `COHORT_ENTRY_DRAIN`, authorize all exact-scope replay/sampled/verification work and no prompt reconciliation or prompt row. Hold partial and newly attached prompts unchanged. A decoder that samples another token remains decode-family pending and continues draining; a completed target iteration does not by itself make FORM eligible.
- If entry-drain outcomes produce `R <= X`, abandon entry intent without allocating a cohort ID and enter the decode-boundary INTERMISSION/NORMAL decision.
- If `R > X` and decode-family pending work becomes zero across the complete exact live scope, transition to FORM. If no decode-family work exists at the initial threshold crossing, direct FORM is legal. In both cases, FORM receives prompt-family members only.
- Reject FORM while any complete-scope stream owns sampled input, mandatory replay, prepared/fresh verification work, or another generating decode obligation. Admission cannot omit that stream to manufacture a uniform prompt cohort.
- Freeze the exact ordered adapter set and exact scales only when FORM binds `active_cohort` for the cohort lifetime.
- Preserve dependency-blocked children mechanically during entry drain. Multimodal never executes in `COHORT_ENTRY_DRAIN`.
- Seed FORM from held incumbents, then extend through one queue lease.
- Permit that FORM lease to be empty when the immediately preceding NORMAL attachment already raised prompt-stream count to `E`; include those attached pairs in the formation proposal before any further target work.
- Admit only tasks with the common formation signature; leave other-signature arrivals queue-owned deferred.
- During the FORM admission transaction, gather non-mutating runtime speculative/synchronization and resident/cache capability facts over the complete control-supplied stream set, have admission calculate one `formation_assessment`, and bind that assessment in `admission_commit` before slot attachment. Keep runtime masks, committed profile and effective reservation input distinct. Do not use mutating `prompt_cache->take()` as proposal-time inspection.
- Permit only MTP-OFF or all-member MTP-IMMEDIATE. Immediate capability requires an immediate-compatible cache restore or immediate prefill from scratch and excludes a declared lifetime that can require stateful MTP-demoting context shift. If that cannot be established for every member, select MTP-OFF rather than deferred MTP.
- Have `server_inference::admission_adapter::apply()` apply the committed exact placement plan once and report `stream_key` values without speculative/cache mutation, then refresh/classify. If attachment/cancellation makes `R <= X`, or introduces any decode-family work, allocate no cohort ID and emit the reviewed INTERMISSION/NORMAL path rather than binding a partial cohort.
- Otherwise, combine held and newly attached stream keys in stable attachment order; allocate `next_cohort_id++` and atomically commit cohort ID, complete ordered membership, frozen profiles and initial prompt cursor.
- After cohort binding, have `server_execution::executor` apply the exact initialization command to every live stream and restore cache under that profile. MTP-OFF removes MTP, clears any pre-existing deferred archive/mode, selects target-only prefill and performs no hidden-state capture/archive allocation. MTP-IMMEDIATE uses only an immediate-compatible restore; otherwise it discards that restore and prefills immediate from scratch rather than falling back target-only.
- Make `COHORT_PREFILL` the first active phase after binding. Only PREFILL and DECODE may contain a non-empty `active_cohort`; NORMAL, entry drain, INTERMISSION and pre-bind FORM contain none.
- Permit no target-model work between final FORM attachment, active-cohort/NORMAL initialization choice, and completion of its speculative/cache initialization. An initialization failure releases the failed exact pair through existing admission failure and forces a recount before target authorization; it does not switch another live member's profile.
- In PREFILL, emit exact `prompt_reconciliation_commit`, reconcile mechanically, publish one global tagged snapshot, and emit `target_batch_commit` only with one contiguous prompt grant per sequence.
- Close the PREFILL barrier only when every live exact stream is reconciled with zero prompt/reconciliation pending work. Prompt completion under the frozen profile runs `common_speculative_begin()` and sampling exactly once, then keeps the resulting sampled-input work visible but unauthorized behind the barrier.
- In DECODE, authorize replay/sampled/verification work only while `R > X`; enter INTERMISSION at `R <= X` before any subsequent NORMAL/FORM work.
- Keep new arrivals queue-owned outside the frozen cohort until the decode-boundary INTERMISSION decision, the next FORM window or return to NORMAL.
- Rotate only the first prompt recipient using the stable-order/pruning rules; never use `prompt_cursor` for decode/speculative participation.
- Keep cancellation, metrics, health and shutdown signalling immediate. Hold global `/lora-adapters` and other model-state mutations until a cohort boundary, then apply them only through `model_mutation_commit` and `server_execution::executor`. Apply only individually reviewed immediate/boundary classifications to slot/cache mutations; no generic control-task bypass exists.
- Invoke no deferred MTP activation/backfill path or activation scan in any cohort phase.
- For MTP-OFF, prohibit immediate MTP, capture/archive allocation, backfill, activation and MTP verification rows for the entire cohort lifecycle.
- For MTP-IMMEDIATE, retain immediate MTP for every member and reserve its maximum rows from the beginning of every applicable decode plan.
- For LoRA-active cohorts, commit MTP-OFF while leaving ngram independently eligible.
- Require every incumbent LoRA member's MTP lifecycle to reach a safe idle/demotion boundary before cohort freeze.
- Keep ngram speculation eligible for LoRA-active cohorts.
- Keep embedding/rerank as NORMAL-only: cohort capability is disabled at startup when --embedding or --reranking is enabled; the cohort phase machine never engages for those tasks and embedding/rerank work always runs in NORMAL. No drain-window or intermission policy for embedding/rerank is needed.
- After every complete `iteration_completion`/cancellation refresh in `COHORT_ENTRY_DRAIN` and DECODE, derive blockers and `R`; at `R <= X`, abandon entry intent or end the active cohort respectively and enter `COHORT_INTERMISSION` before another target authorization.
- In INTERMISSION, use one queue-owned cancellation-visible lease to select at most the oldest ready, mechanically placeable multimodal task. Once attached, emit only that task's single-stream `target_batch_commit` or task-scoped `external_target_commit` until it completes/cancels.
- Hold every partially drained text survivor through INTERMISSION with pending work visible but unauthorized and without prompt/decode preparation, speculative drafting, verification rows or target work.
- After the selected task completes/cancels, leave INTERMISSION even if another multimodal task waits. A surviving held decoder returns to NORMAL for mixed scheduling; only a decoder-free boundary may open FORM when a prompt-cohort proposal is available. If no multimodal task was ready, take the same transition without target work.
- On PREFILL-side `R <= X`, return directly to NORMAL because the accepted multimodal priority point is decode-boundary-only.
- Carry no freshly drafted unexecuted block across the decode boundary. Preserve any outcome-created replay unchanged through intermission and make it mandatory prefix work in the first subsequent NORMAL plan. Keep any MTP-OFF survivor whose target context advanced without MTP capture OFF; NORMAL may reconsider only a no-target-work survivor, newly admitted work, or otherwise mechanically eligible work.
- If the same surviving exact stream later re-enters cohort policy, bind it to the new cohort ID rather than retaining the ended lifecycle ID.
- Keep the runtime cohort policy absent outside tests so no numeric sentinel or test threshold can enable cohort mode yet.

### Non-server workstream

No source changes. Cohort profiles select among existing common speculative and
cache behaviors; they do not add a common scheduler, cohort identity, new MTP
lifecycle, sampling path, model-execution path, or backend work.

### Gate

- Cohort PREFILL target manifests contain no decode/verification rows.
- Cohort DECODE target manifests contain no prompt rows.
- Every cohort iteration retains one monotonic `iteration_id` through staged reconciliation/preparation, `target_batch_commit`, all `batch_view` values and one `iteration_completion`; only `target_batch_commit` authorizes target execution.
- No cohort barrier, `R`, phase or admission decision consumes a partial-view outcome.
- The first cohort preparation observes the exact speculative profile committed before cache restore/attachment, and that profile never changes through PREFILL/DECODE.
- Worst-case decode reservation selects every fitting member before one bulk draft call.
- With `n_batch=32768`, `n_parallel=8`, and MTP-IMMEDIATE `n_max=3`, all eight members reserve only 32 logical rows and fit together; MTP-OFF reserves zero MTP rows.
- With ngram-mod `n_max=64`, the same eight members reserve 520 logical rows and still fit without a cap.
- MTP-OFF/LoRA-active cohorts may therefore have 520-row ngram verification work even though MTP is excluded.
- Every `prepared_decode_outcome` appears in the same iteration's target manifest and cannot cause reselection.
- `COHORT_ENTRY_DRAIN` accounts for every incumbent exact stream, authorizes every decode-family member, holds every prompt-family member, and owns no `active_cohort`.
- The currently executing mixed NORMAL manifest completes before entry intent is evaluated.
- No `cohort_id` is allocated during entry drain or pre-bind FORM; `R >= E` alone never creates a cohort.
- FORM cannot bind while any exact-scope decode-family work remains, and no decoder may be omitted from the scope to permit binding.
- Entry drain remains active when a decoder's outcome produces another sampled input; it ends only through decoder completion/cancellation, decoder-free FORM eligibility, or `R <= X` abandonment.
- A partially prefilled stream and a fully cached stream owing last-token/logit evaluation both remain held prompt-family work. A prompt-complete stream with sampled input is decode-family work.
- With no decode-family work at threshold crossing, direct FORM remains pre-bind and allocates no cohort ID until its exact scope passes assessment and attachment reconciliation.
- An entry-drain reduction to `R <= X` consumes no cohort ID and follows the INTERMISSION/NORMAL boundary without FORM.
- Only PREFILL and DECODE contain a non-empty `active_cohort`; the first active command after successful binding is PREFILL initialization/reconciliation, never decode work.
- The first target manifest after FORM names the exact stream keys bound to the newly allocated cohort ID.
- Every later cohort command, target manifest, mandatory post action and outcome retains that cohort ID while stream keys remain execution identity. INTERMISSION begins only after that cohort lifecycle is cleared and its multimodal task has no cohort ID.
- Cohort IDs increase monotonically per process and remain unchanged through PREFILL, DECODE and membership pruning while `R > X`; reaching `R <= X` clears the lifecycle without changing or reusing its ID.
- Cancellation, slot reuse, parent/child and replay preserve exact `stream_key` identity; slot reuse can enter only a later cohort ID.
- Aborted FORM leases and ordinary NORMAL leases do not allocate cohort IDs, and no lease ID is accepted as a cohort ID.
- Entry/exit tests are parameterized over `E` and `X`; no example count appears in controller branches.
- Two prompt streams plus the stream that reaches example `E = 3` may proceed directly through FORM and form one prefill cohort before the next target batch when the complete exact scope has no decode-family work; earlier finishers wait at the barrier.
- With two decoders plus one held prompt at example `E = 3`, parameterized exit tests prove `X = 1` reaches the boundary after both decoders while `X = 2` reaches it after the first; with no ready multimodal task, the zero-work intermission permits the corresponding NORMAL prompt-only or mixed decode/prefill work.
- `WAIT_OTHER` children do not satisfy `E`; activated parent/child completion streams do.
- Control derives classifier sets, lifecycle/task blockers, exact scope and `R` from passive dependency/task/capability facts; admission alone calculates formation compatibility for that scope; no adapter, largest-group calculation or event-maintained counter owns control policy.
- Incumbent multimodal work blocks entry in NORMAL; queued multimodal work cannot execute before a decode-side `R <= X` boundary.
- INTERMISSION selects one oldest ready task, exposes no helper-internal batch authority, holds all text survivors and ends after that task even when another waits.
- INTERMISSION outcome tests distinguish partial drain with a decoder survivor returning to NORMAL from decoder-free completion proceeding directly to FORM.
- Lower-threshold boundary carries no freshly drafted unexecuted block, preserves outcome-created replay through intermission as mandatory first-NORMAL prefix work, keeps target-advanced MTP-OFF survivors OFF, and lets later NORMAL re-evaluate ngram plus no-target-work/new mechanically eligible work.
- Early first-token sampling happens exactly once.
- The barrier predicate is zero prompt/reconciliation pending work for every live exact stream, never categorical `GENERATING` state.
- Cohort prompt spans remain contiguous without invoking deferred-MTP capture.
- MTP-OFF cohort tests observe no capture/archive allocation, activation scan/backfill or MTP verification rows, including when global NORMAL deferred capture is enabled.
- MTP-IMMEDIATE tests prove every member is immediate at formation and no member changes MTP mode during the cohort.
- MTP-IMMEDIATE cache tests use only compatible restore or immediate prefill from scratch and never target-only fallback; requested-lifetime tests select MTP-OFF whenever a stateful demoting context shift can be required.
- Formation falls back as a whole to MTP-OFF rather than admitting a mixed immediate/deferred/OFF cohort.
- Every member retains the frozen exact adapter signature.
- No adapter application changes during `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE.
- LoRA-active cohorts execute MTP-OFF while ngram remains functional.
- Identical-signature members share the existing static adapter application without adapter-weight copying.
- Stable-order cancellation/completion tests prove exact cursor normalization and advancement only with `target_batch_commit`.
- Cohort capacity tests prove every active decoder receives at least one sampled row or the iteration reports explicit infeasible capacity; prompt fairness never selects decode participation.
- Operation-class tests prove immediate cancellation/metrics/health/shutdown, boundary-gated global model mutation, and the reviewed behavior of each slot/cache mutation.
- Cohort mode remains unavailable to users.

### Rollback

Revert Phase 6 before Phase 5.

## Phase 7 — Delete residue, expose configuration and observability

Separately committable: yes; metrics may be a second commit in the same phase.

### Authority

No transfer. This exposes the completed architecture and verifies that each earlier takeover removed its obsolete authority in the same commit.

### Configuration

```text
--cohort-batching-threshold E
--cohort-batching-exit-threshold X
LLAMA_ARG_COHORT_BATCHING_THRESHOLD
LLAMA_ARG_COHORT_BATCHING_EXIT_THRESHOLD
```

- With neither option configured, cohort mode is disabled and controller-driven NORMAL is preserved.
- Enabling requires both configured values with `0 < X < E`; a lone or invalid public option pair is rejected at argument parsing.
- `R` counts `independently_runnable_text && cohort_capable` streams. Control-owned lifecycle/task blockers and admission-owned exact-scope `formation_assessment` remain separate. There is no request-count, largest-compatible-subset, raw occupied-slot-count, multimodal-task count or fixed numeric fallback.
- Existing `--cont-batching` controls NORMAL only.
- Existing speculative active limits and deferred-MTP configuration retain their NORMAL behavior and do not affect the immutable cohort profile.
- No prompt-quantum option.

### Server workstream

- Consume the two resolved threshold values as plain server parameters; construct `std::optional<inference::control::config>` inside `tools/server`; do not put policy types in `common`.
- Wire that resolved control configuration into serving-context construction and the single controller instance.
- Keep threshold interpretation, eligible-stream counting, hysteresis and every phase transition inside server-local control policy.
- Expose effective enablement and the resolved `E`/`X` values through server properties, structured logs and server documentation.
- Perform the authority-residue deletions/checks and server observability work below.
- Add server integration tests proving absent options preserve controller-driven NORMAL, valid paired options enable cohort policy, and `--cont-batching` remains NORMAL-only.

### Non-server workstream

- Add the two plain configuration fields to `common/common.h`.
- Add paired CLI and environment parsing to `common/arg.cpp`, following the existing server-option plumbing without introducing `inference::*` types or policy behavior.
- Add focused argument tests for absent, valid-pair, lone-option and invalid-order cases, including the required `0 < X < E` relation.
- Keep help/examples explicitly server-scoped. The shared layer resolves values and rejects an invalid public pair; it does not count streams, select cohorts, or interpret phases.

### Deletions and checks

Verify Phase 3 already deleted the exact legacy catalogue at `tools/server/server-context.cpp:3629-3745`, `3754-4292`, and `3546-3612`.
- Verify no scheduling use of `SLOT_STATE_*` remains outside the enumerated mechanical translator and response/outcome branches.
- Verify Phase 4 already deleted inference promotion from release paths when control took admission authority.
Verify Phase 5 already deleted both independent legacy MTP activation call sites (`tools/server/server-context.cpp:3614-3618`, `4512-4518`) and replaced them with the single post_decode generating scan.
- Verify control stores no per-stream progress/pending-work/reconciliation/prepared/replay/physical-position mirror and no event-maintained `R` catalogue.
- Verify `snapshot_reader` derives no runnable/capable/blocker class, compatibility group, `R`, pending-work selection or grant; verify `admission_adapter` does not assess formation compatibility; verify execution discovers no work or residual allocation.
- Verify exactly one `server_inference::admission_adapter` owns both placement planning and application for one retained lease-bound transaction, and no second allocator or applier exists.
- Verify exactly one typed `server_execution::executor` dispatches all authorized execution command kinds, while `update_slots()` alone assembles `iteration_completion`; individual execution outcomes cannot close or advance an iteration.
- Verify generic proposal/commit/post-action types and generic `inference::types`, `facts`, `utils`, or `scheduler` namespaces do not exist.
- Verify the existing `server_queue` remains the concrete type/owner and no conflicting namespace or second placement calculation exists.
- Verify cache/speculative initialization is dispatched through `server_execution`, not hidden in snapshot translation, placement or attachment.
- Verify common code contains no server `inference::*` policy types.
- Delete any test-only cohort switch.
- Verify no runtime fallback to the legacy scheduler remains.
- Remove synthetic `NEXT_RESPONSE` only if the replacement still guarantees a fresh queue/control sweep before each inference turn; otherwise retain it.

### Observability

- Current global phase, monotonic `iteration_id`, active monotonic `cohort_id`, and exact ordered `stream_key` membership in structured logs/debug APIs.
- Pre-cohort entry intent, complete exact drain scope, decode-family pending count/reasons, held prompt-family count, entry-abandonment cause, and the first active phase after cohort binding.
- `iteration_completion` kind and terminal reason, distinguishing target, external, model-mutation, admission-only, zero-work and failure closure.
- Admission `lease_id` plus lease/proposal/commit counts, kept distinct from `cohort_id`.
- Proposed versus committed NORMAL compatibility group; proposed versus committed exact-scope cohort `formation_assessment`; maximum verification reservations, actual decode rows and prompt grants.
- Configured versus effective ngram maximum, fair per-member cap, remainder assignment and sampled-only fallback count.
- Eligible implementation maximum used by dynamic speculation.
- NORMAL residual rows released by shorter drafts.
- Frozen cohort adapter signature and blocked adapter-switch/global-mutation counts.
- Barrier-held members and arrivals held outside the current cohort until FORM or lower-threshold NORMAL exit.
- INTERMISSION predecessor cohort ID or pre-cohort `COHORT_ENTRY_DRAIN` marker, entry cause, selected exact multimodal task, queue wait, exclusive duration, helper-call/chunk totals, completion/cancellation and zero-work bypass count.
- Frozen cohort speculative profile, selection reason, MTP-OFF/MTP-IMMEDIATE counts, suppressed cohort capture/archive/backfill work, and MTP/ngram row composition.
- Current `R`, configured `E`/`X`, entry/exit transition cause, phase duration and per-cohort makespan attribution.
- Per-member reconciled prompt coverage, output-committed count, pending sampled input, derived pending-work set and authorization/hold reason.
- Tagged `prompt_reconciliation_outcome`/`prepared_decode_outcome` values, fresh/replay origin, maximum reservation, exact row cost and target-manifest membership.
- Projection refresh cause and complete `target_batch_outcome`: committed advancement, prepared retraction, replay creation/consumption, completion, cancellation or release.
- Physical target/draft positions explicitly marked diagnostic and non-semantic.

Do not place `iteration_id`, `cohort_id`, lease ID, task ID or `stream_key` in Prometheus labels. Aggregate pending/authorized rows by phase/work class, held/blocked counts, committed advances, prepared retractions, refresh causes and iteration/outcome mismatch counts. Use high-cardinality identities only for structured phase/admission/execution traces, row-composition logs, cancellation reports and slot-reuse diagnosis.

### Gate

- Non-server argument tests pass before the server feature is exposed, and common headers contain only plain configuration values rather than scheduler policy types.
- Exactly one `inference::control::controller` exists per serving context.
- Admission/batching contain no commit paths.
- Server adapters contain no stream/group/grant discovery branches.
- One `admission_adapter` plans/applies a lease-bound placement transaction; one typed executor applies authorized execution; neither shares policy with control nor iteration-closure authority with `update_slots()`.
- Control alone derives runnable/capable/lifecycle-blocker sets, exact formation scope and `R` from passive facts; admission alone calculates that scope's adapter/speculative compatibility; no stored counter or duplicate compatibility calculation can drift.
- Only `target_batch_commit`/`external_target_commit` reach target execution, and `target_batch_outcome` publishes only after every `batch_view` and mandatory post action settles.
- Every target invocation and every NORMAL deferred-MTP activation has a control commit; cohort phases have no activation path.
- Disabled-mode regressions and parameterized `E`/`X` cohort/hysteresis tests pass.

### Rollback

Phase 7 alone may be reverted to hide the feature while retaining the controller architecture. Restoring legacy authority is not a runtime rollback mechanism.

## Phase 8 — Validation and production decision

No architecture commit unless testing identifies a policy defect.

### Server workstream

CPU regression includes control/admission/batching unit tests; monotonic iteration and cohort identities; strong lease/task/slot/stream/cohort/iteration separation; exact placement-plan single application; runnable/capable/lifecycle-blocker classification plus admission-owned exact-scope compatibility; parameterized `E`/`X` entry intent, exit and hysteresis; uniform-work entry drain with no provisional cohort; no decoder outside an active prompt cohort; no largest-compatible-subset or fixed threshold; `WAIT_OTHER` exclusion and post-copy parent/child counting; lower-threshold abandonment and zero-work NORMAL return; incumbent multimodal blocking; decode-side-only INTERMISSION; exact intermission identity; oldest-task one-boundary quota; opaque helper batches; survivor holding/re-entry; stable ordered membership and cursor pruning/advancement; prompt cursor never selecting decoders; explicit infeasible cohort minimum-row capacity; speculative-profile commit before attachment and execution-owned initialization; cancellation cutover; NORMAL target-manifest/deferred-MTP equivalence; activation before reservation; MTP-IMMEDIATE and MTP-OFF mechanics; MTP/ngram row accounting; exact selected-set bulk drafting; replay through exit/intermission; residual ngram caps and sampled-only fallback; prompt cache/checkpoints/context shift; early sampling; output/NextN/verification/replay alignment; operation-class behavior; embedding/rerank; static adapter signatures; LoRA MTP-OFF; ngram with LoRA; and complete-verification-prefix retry behavior.

Server validation also verifies that all target, admission and NORMAL MTP-timing decisions are committed by `inference::control`, server adapters remain mechanical, and no legacy authority path or test-only cohort switch remains.

Progress/iteration regression additionally covers:

- Lifecycle-gated stale `n_decoded`, `sampled` and `has_next_token` exclusion for reused slots.
- Fully cached prompt reconciliation with mandatory last-token logits evaluation.
- Exact `prompt_reconciliation_commit` -> tagged outcomes -> global snapshot -> prompt-grant proposal ordering.
- Monotonic `(reconciled_prompt_coverage, output_committed_count)` versus retractable prepared extent and mutable physical KV/cache positions.
- Pending work, priced proposals and authorized work as distinct domains.
- Prepared fresh descriptors remaining bound to the selected set; replay retained-token count versus total row price.
- Runtime speculative masks, frozen cohort profile and effective post-activation reservation input remaining distinct.
- One monotonic `iteration_id` correlating distinct commands/outcomes and exactly one `iteration_completion`, including explicit admission-only, zero-work, model-mutation and terminal-failure variants.
- No projection/phase/`R`/admission refresh during preparation, retry, or a partial `batch_view`.
- Exact outcome identity captured before release/reset, including parent copy, cancellation, replay and slot reuse.
Exact Phase 3 categorical scheduling deletion and exact Phase 5 removal of both legacy activation sites.
- Absence of any legacy categorical scheduling interpretation after Phase 3.
- One iteration lineage through preparation, retry views, target execution, post-decode, and complete outcome.
- Controller stores no copied prompt, sampled, replay, checkpoint, cache, speculative, or frontier state.

### Non-server workstream

- Run the focused common argument-parser regression for the paired CLI/environment surface.
- Verify the refactor changes no common speculative, sampling, cache/checkpoint, model-execution or backend/microbatch implementation behavior.
- Treat ROCm runs as cross-runtime validation of the server policy against unchanged common/model/backend mechanics, not as authority or implementation work in those layers.

### Combined production gate

Controlled ROCm benchmarks compare cohort-disabled NORMAL, `--no-cont-batching`, illustrative `E = 3` with both `X = 1` and `X = 2`, and at least one wider hysteresis pair to prove behavior is configuration-driven, with:

- Retained 8K prefill/4K decode at `b32768/u1536`.
- One decoder plus one 128K prompt.
- Bursts of three, four and eight long prompts.
- Equal and skewed prompt/decode cohorts.
- Staggered arrivals in every phase.
- Repeated configured `E`/`X` crossings, including barrier entry, full decoder drain, and early return to NORMAL mixed decode/prefill.
- `n_cmpl` parent prompt completion and child-stream activation.
- Cohort MTP-OFF and homogeneous MTP-IMMEDIATE profiles.
- MTP-OFF cohorts while global NORMAL deferred capture support is available.
- NORMAL active-limit/deferred-MTP cases proving authority-migration equivalence.
- Ngram-only, MTP-only and dynamic speculation.
- Base/no-LoRA cohorts and identical static LoRA cohorts.
- Mixed-signature arrivals and global adapter changes at cohort boundaries.
- aLoRA remaining in NORMAL.
- LoRA cohorts with ngram enabled and MTP excluded.
- Capacity-constrained ngram cases above and below configured `n_min`.
- Cache/checkpoint/context-shift cases.
- Multimodal arrival during a text cohort.
- Multimodal already active at attempted entry, multiple queued multimodal tasks at the boundary, task cancellation and task prompts containing several internal media-helper batches.

Measure aggregate accepted tokens/s, prefill/decode throughput, TTFT, inter-token latency, queue delay, cohort makespan, logical utilization, physical microbatch composition, GPU utilization, draft acceptance, frozen-profile selection, MTP/ngram row composition, and absence of cohort archive/backfill traffic in MTP-OFF mode. Trace validation additionally proves every executed row belongs to one `target_batch_commit`, logical progress never decreases, prepared retraction and physical movement are separate, sampled debt is created/consumed exactly once, and no policy refresh occurs between `batch_view` values.

The production decision requires the server authority/regression results, the non-server configuration/runtime checks, and the controlled ROCm measurements together. A validation result that requires changing common speculative, sampling, cache/checkpoint, model or backend mechanics opens separately reviewed follow-on scope rather than silently expanding this plan.

## Authority by phase

| Phase | Target-work commit | Admission commit | MTP timing commit | Proposal owners | Duplicate authority |
| --- | --- | --- | --- | --- | --- |
| 1 | Existing server | Existing server | Existing server | Leaf-pure admission/batching calculations only | No mutable controller or applying adapter exists |
| 2 | One legacy target-manifest producer | Existing server | Existing server | Legacy producer plus extracted passive/mechanical contracts | No; executor is mechanical and lineage follows legacy authority |
| 3 | Control `target_batch_commit` / `external_target_commit` for NORMAL | Existing admission path | Existing MTP path | `inference::batching` | No; NORMAL transaction controller lands and legacy planner is deleted |
| 4 | Control target commands | Control `admission_commit` | Existing MTP path | Admission and batching | No; queue lease and `admission_adapter` mechanisms land atomically |
| 5 | Control target commands | Control `admission_commit` | Control `mtp_activation_commit` | Admission, batching, speculative eligibility | No; both legacy MTP activation sites deleted |
| 6 | Control target/external/model-mutation commands | Control `admission_commit` | NORMAL: control activation command; cohort: immutable profile, no activation | Admission, batching, speculative eligibility | No |
| 7 | Control target/external/model-mutation commands | Control `admission_commit` | NORMAL: control activation command; cohort: immutable profile, no activation | Same | No; obsolete paths deleted |

Non-server source changes occur only in Phase 7 configuration plumbing; Phase 8 performs non-server validation without planned source changes. Neither workstream step acquires target-work, admission, batching, phase-transition or MTP-timing authority outside the server controller.

Phase 2 also contains a non-applying diagnostics comparator, but it owns no proposal application, control mutation, fairness state or runtime mutation. Phase 3 deletes it with the legacy categorical planner and introduces the first executable NORMAL controller. Phase 4 adds the admission transaction and queue-owned lease/adapter seam. Phase 6 alone adds executable cohort transitions, binding and intermission state.

## Final approval boundary

Implementation does not begin until the architecture review accepts:

1. The canonical namespace split: value-only identity/profile vocabularies, proposal-only admission/batching, control-only commands, passive server snapshots, mechanical server adapters, and server-execution outcomes.
2. Existing-`server_queue`-owned cancellation-aware leases and one exact placement plan applied once.
3. Dedicated monotonic per-process cohort identity atomically bound to exact initial membership, immutable adapter/speculative profiles and initial prompt cursor.
4. Separation of task, slot, `stream_key`, queue-lease, cohort and iteration identity domains.
5. Committed mutating preparation.
6. Exact-task-scoped multimodal authorization with opaque helper internals, incumbent NORMAL blocking and one-task decode-boundary INTERMISSION priority.
7. The six-phase controller including pre-cohort ENTRY_DRAIN, decode-boundary INTERMISSION, explicit runnable/capable/lifecycle-blocker classification, admission-owned exact-scope formation assessment, `WAIT_OTHER`/`n_cmpl` behavior, configured `E`/`X`, and lower-threshold transition before the next target batch.
8. Immutable exact adapter signatures, no largest-compatible-subset or heterogeneous lanes, stable membership order, exact cursor pruning/advancement, and prompt-only rotation.
9. Homogeneous cohort speculative profiles: MTP-OFF zero-work semantics, optional all-member MTP-IMMEDIATE, LoRA MTP-OFF, ngram eligibility and safe incumbent demotion.
10. Worst-case selection-before-bulk-drafting, no new prepared carry-over lifecycle, and mandatory existing replay blocks.
11. Maximum-eligible speculative accounting and participation-first ngram caps.
12. The indivisible complete-verification-prefix contract, prompt-tail-only retry partitioning, the resolved unfit outcome (typed `verification_prefix_unfit` on the existing terminal cleanup/error path when the prefix cannot fit), and preservation of existing speculative post-processing mechanics.
13. Explicit operation classes during entry/frozen cohorts: immediate service operations, boundary-gated model mutations, individually reviewed slot/cache mutations, and ordinary inference admission.
14. NORMAL deferred-MTP authority-migration equivalence with no cohort activation lifecycle.
15. The distinct NORMAL activation/begin and cohort frozen-profile/begin ordering.
16. Reverse-order rollback semantics.
17. The server/non-server workstream split plus separate compile-time and runtime-flow contracts: common owns plain option values/parsing only; all scheduling policy and commands remain server-local.
18. Lifecycle-gated `(reconciled_prompt_coverage, output_committed_count)`, with prepared extent and physical positions separate and no persistent stream mirror.
19. Staged exact-stream prompt reconciliation followed by one global passive snapshot and control-committed grants.
20. Control-owned stream classification, lifecycle/task blocker set, exact scope and `R` derivation from passive lifecycle/task/dependency/capability facts, plus admission-owned adapter/speculative compatibility assessment for that supplied scope.
21. One monotonic `iteration_id` with distinct commands and exactly one `iteration_completion`; target iterations additionally require complete `target_batch_outcome` closure.
22. Exact Phase 3 categorical scheduling deletion and isolated Phase 5 NORMAL MTP-timing migration.
23. `server_context::update_slots()` as the mechanical dispatch pump with no scheduling discretion.
24. Canonical target-manifest/server-batch/batch-view/`n_batch`/`n_ubatch` vocabulary.
25. Cache/speculative initialization owned by `server_execution`, never passive translation, placement or attachment.
26. Uniform-work cohort start: `R >= E` creates entry intent only; every decoder drains while prompts are held; FORM binds only a decoder-free prompt-family scope; only PREFILL/DECODE own `active_cohort`.
27. Collapsed server adapters: one placement/attachment `server_inference::admission_adapter`, one typed `server_execution::executor`, and `update_slots()` as the sole `iteration_completion` assembler.
