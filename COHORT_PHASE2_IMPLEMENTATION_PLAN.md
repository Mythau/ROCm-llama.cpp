# Cohort Phase 2 Implementation Plan — Mechanical execution extraction under legacy authority

Status: standalone implementation plan for the Phase 2 workers. Architecture authority remains
`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md` (Phase 2 section, lines 489-572) and
`COHORT_BATCHING_CONTROLLER_DESIGN.md`; the approved delta is
`COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md`. This document does not authorize any new design
decision. Where the source disproves a provisional Phase 1 DTO shape, this plan records the
replacement contract and the exact disproving seam; Phase 2 is explicitly permitted to replace
any provisional Phase 1 DTO shape the real seam disproves
(`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:507`).

Tree audited: working tree `C:\AI\runtimes\llamacpp\2026-08-12\source\llamacpp-yolo-allpatches-gfx1100-gfx1201`,
branch `rocm-yolo`, HEAD `213583f9f` ("docs: clear decision 3 stale residuals found by architecture review").
All `tools/server/server-context.cpp` line numbers below are this tree, which carries the pre-landed
Phase 5 post-decode generating-scan edit (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:9`).
UNVERIFIED marks claims the plan could not re-verify against an authoritative source; workers
re-verify them at the stated step.

## 0. Objective and scope

### 0.1 What Phase 2 must produce

- One runtime correlation contract derived from the real legacy turn: monotonic `iteration_id`,
  prepared/reconciliation lineage, `batch_view`, `server_batch`, `target_manifest`, one complete
  `target_batch_outcome`, one `iteration_completion`, and explicit non-target completion variants
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:507`).
- One temporary legacy intent/target-manifest producer: existing selection is *moved* into it, not
  copied (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:508`).
- `server_inference::snapshot_reader`: sole passive, history-free translator, plus a diagnostics-only
  progress/pending-work comparator that never applies anything
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:509`).
- `server_context::update_slots()` reshaped into the mechanical pump: snapshot → legacy decision →
  exact dispatch → complete outcome → refreshed snapshot
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:510`; `COHORT_BATCHING_CONTROLLER_DESIGN.md:614-628`).
- One typed `server_execution::executor` façade extracted from the real seams: preparation overloads
  (maintenance/context shift, draft preparation, prompt reconciliation, cache/speculative init) and
  target/external overloads (`server_batch` construction, task-scoped multimodal helpers, target/spec
  work, mechanical retry views, complete outcomes)
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:511`).
- Staged prompt reconciliation: the legacy planner names exact prompt-reconciliation members before
  any STARTED-state mutation; outcomes are iteration-tagged `prompt_reconciliation_outcome` values;
  one global snapshot is published between reconciliation and grants; unchanged legacy authority
  chooses/grants rows (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:512-513,515-526`).
- The mechanical-turn invariants: one legal grant for every mutably prepared live prompt stream,
  `1 + effective draft maximum` reservation, bulk-draft only the selected set, every
  `prepared_decode_outcome` in the same iteration's finalized legacy target manifest, no
  scheduler carry-over (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:527-531`).
- Target-manifest block offsets, contiguous verification prefix, retry metadata, replay blocks as
  mandatory known-size prefix members, prompt-tail-only retry splitting, and the resolved
  `verification_prefix_unfit` path into the existing terminal cleanup/error machinery
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:532-535`).
- Mechanical accumulation of `batch_view` results, exact stream/block/offset identity capture before
  release/reset, mandatory post actions, one complete `target_batch_outcome`, one
  `iteration_completion`, admission-only and zero-work completion variants
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:536`).
- The non-applying comparator: projected pending work vs the finalized legacy target manifest plus
  the complete outcome only, shadow evidence, never an applying scheduler
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:537-539`).
- Tests that extend/reshape the dormant test surface for the comparator and contract extraction
  without a model, keeping `tests/test-speculative-control.cpp` passing against the modified tree
  (plan task statement; `tests/CMakeLists.txt:262`).

### 0.2 What Phase 2 must NOT do

- **No authority transfer.** A single legacy planner remains the sole runtime scheduling authority;
  `server_execution` becomes mechanical (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:493-495`).
  `inference::control` exists only as the Phase 1 value-only declarations
  (`tools/server/inference-control.h:1-20`: `phase`, `config`, `active_cohort`); no command type, no
  `controller`, no `next_action()`, and no executable control path may exist after this phase.
- No new selection, compatibility, fairness, phase, membership, admission or grant logic. The moved
  legacy planner keeps its existing decisions; the pump and executor may not substitute any.
- No prepared-but-unscheduled scheduler carry-over lifecycle: the existing reuse path
  (`tools/server/server-context.cpp:3667-3671`, reuse of a partial `spec_draft`) must not become a
  scheduler policy (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:530`).
- No opportunistic preparation of another speculative member from freed NORMAL prompt capacity
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:241`).
- No common/runtime/backend changes and no `llama_decode` change (Section 5).
- **NORMAL target manifests must equal the Phase 0 fixtures.** The fixture
  `tests/python/fixtures/cohort_batching_normal_manifest_baseline.json` (schema_version 1,
  "source-derived-normal-scheduler-baseline"; JSON lines 2-3) and
  `COHORT_BATCHING_PHASE0_NORMAL_BASELINE.md` stay the acceptance oracle; the fixture notes that
  `iteration_id` is unavailable until Phase 2 (JSON line 7) and the baseline notes that legacy
  never reserves worst-case rows before drafting
  (`COHORT_BATCHING_PHASE0_NORMAL_BASELINE.md:25-27,29-33`).

## 1. Runtime correlation contract (derived from the real legacy turn)

This section states the exact vocabulary the Phase 2 code must implement. Canonical meanings are fixed
by `COHORT_BATCHING_CONTROLLER_DESIGN.md:589-611` and `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:312-331`;
every implementation name below binds to one of those terms.

### 1.1 Monotonic `iteration_id`

- Value-only strong type `inference::identity::iteration_id { uint64_t value; }` already exists
  (`tools/server/inference-identity.h:25-29`). Phase 2 adds the single runtime monotonic counter,
  owned by the legacy planner seam (not by `inference::control`), incremented once per settled
  `update_slots()` turn.
- Meaning: "monotonic per-process identity for one snapshot-to-complete-outcome scheduling/execution
  transaction" (`COHORT_BATCHING_CONTROLLER_DESIGN.md:595`). One lineage correlates distinct
  preparation and reconciliation stages and the final target batch; only the final target batch
  authorizes target execution (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:67`).
- The synthetic Phase 0 fixture label `legacy_turn` maps to `iteration_id` in Phase 2; fixture
  field `iteration_note` documents this hand-off (JSON line 7).
- Every outcome struct below carries `iteration`; `server_batch`/`batch_view` do not carry it — the
  pump scopes them by the single live `iteration_id` for their turn
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:632-659`).

### 1.2 Prepared/reconciliation lineage

- `prepared_decode_outcome` is an opaque, lineage-tagged descriptor: block identity, exact owner,
  fresh/replay origin, actual atomic target rows; it never re-enters candidate discovery or
  reselection (`COHORT_BATCHING_CONTROLLER_DESIGN.md:442-451`;
  `COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:71-73`).
- `prompt_reconciliation_outcome` carries `iteration`, exact `owner`, `prompt_total`,
  `reconciled_prompt_coverage`, `contiguous_cap` (`COHORT_BATCHING_CONTROLLER_DESIGN.md:431-440`).
  `reconciled_prompt_coverage` exists only as this tagged outcome of authorized mutating
  reconciliation, never as a passive read of `slot.prompt.tokens`, `n_prompt_tokens_processed`, or
  physical KV positions (`COHORT_BATCHING_CONTROLLER_DESIGN.md:356-359`;
  `COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:21-24`).
- **Phase 1 DTO replacement, disproved by the seam:** `server-execution-outcome.h:5-12` is
  `prompt_reconciliation_result` with `last_logit_pending` and `live` booleans and no
  `iteration`. The design contract instead requires `iteration`, `prompt_total`,
  `reconciled_prompt_coverage`, `contiguous_cap` — the flags do not survive because reconciliation
  coverage is the tagged semantic and the final-manifest rows already carry the pending-last-logits
  truth (`COHORT_BATCHING_CONTROLLER_DESIGN.md:431-440`). Phase 2 reshapes the file to
  `prompt_reconciliation_outcome` and moves the producer-only result away from the dormant test
  surface shape; the legacy producer owns the members (design: "results are owned by their mechanical
  producers", `COHORT_BATCHING_CONTROLLER_DESIGN.md:230`).
- **Phase 1 snapshot DTO replacement, disproved by the seam:** `server-inference-snapshot.h:40-62`
  declares `raw_stream_state` / `project_current_task` and mixes raw physical fields with projected
  lifecycle-gated fields in one struct. The real reconciliation seam
  (`tools/server/server-context.cpp:3786-4342`) mutates prompt/cache/checkpoint/speculative/memory
  state during STARTED processing, so "projection" must be the *post-reconciliation* global snapshot,
  not a pre-mutation read. Split per `COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:106-122`: the
  snapshot contains raw liveness/lifecycle/task/dependency/adapter/speculative facts plus the
  lifecycle-gated `(reconciled_prompt_coverage, output_committed_count)` projection; prepared extent
  and physical KV/cache positions remain separate raw facts
  (`COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:22-30,35-38`). `raw_*` members may keep their names but
  must not be re-interpreted as progress.

### 1.3 `batch_view`

- Mechanical retry/post-processing view over a `server_batch`, never a new plan
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:605`). The real producer is
  `batch.get_view(off, n_tokens)` at `tools/server/server-context.cpp:3469`; the loop boundary
  `off_next = off + n_tokens` advances only on successful decode (`server-context.cpp:3475-3484`).
- No view is constructed by the executor from anything but the committed `server_batch`; retry may
  only shrink `n_batch` for the same `off` (`server-context.cpp:4421-4428`).

### 1.4 `server_batch`

- Server storage encoding of the finalized legacy target manifest
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:604`). It is the existing storage type produced by
  `batch.clear()` (`server-context.cpp:3633`), `batch.add(...)`
  (`server-context.cpp:4241-4245`), `handle_last_sampled_token(batch)`
  (`server-context.cpp:639-676,3754-3757`) and rendered by `batch.render()`
  (`server-context.cpp:3433`). Phase 2 adds no second storage type.

### 1.5 `target_manifest`

- Exact logical target rows, owners, offsets, output requirements and verification-prefix layout
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:602`). Phase 2 introduces it as the legacy-intent producer's
  output value derived from the rows the legacy planner actually added, with the additions required by
  `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:532`:
  - per-block byte/logical **offsets** into `server_batch`;
  - a **contiguous verification prefix** — the complete sampled/speculative verification union laid
    out as one indivisible prefix while retaining each stream's atomic block boundary
    (`COHORT_BATCHING_CONTROLLER_DESIGN.md:665`);
  - **retry metadata** sufficient to guarantee the complete prepared union is preserved in the first
    processed view under current `post_decode()` mechanics
    (`COHORT_BATCHING_CONTROLLER_DESIGN.md:663-667`).
- Manifest rows are the planned execution intent; authority to execute them stays with the legacy
  planner in this phase (no `target_batch_commit` emission — that is Phase 3,
  `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:573-618`).

### 1.6 Complete `target_batch_outcome`

- One complete result published only after every view and mandatory post action settles
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:608`). Contents: complete exact-stream advancement, replay,
  completion, cancellation and failure results captured **before** release/reset erases task identity
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:453-457`).
- Captured before `slot.release()` runs its cleanup (`tools/server/server-context.cpp:678-707`,
  including `reset()` at 703 and `callback_on_release(id)` at 705), so `stream_key = {slot_id,
  task_id}` is recorded while `slot.task` is still valid.

### 1.7 `iteration_completion` and non-target completion variants

- Control-consumed proof that every command and required outcome for one `iteration_id` settled; a
  target result is one possible payload (`COHORT_BATCHING_CONTROLLER_DESIGN.md:609`).
- Phase 2 requires the following completion variants, none of which may fabricate target results
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:659`):
  1. `target_batch_completion` — one complete `target_batch_outcome`.
  2. `admission_only_completion` — the turn advanced queue/slot lifecycle but produced no target work.
  3. `zero_work_completion` — the pump's all-idle fast path fired
     (`tools/server/server-context.cpp:3406-3420`, `return` at 3419).
  4. `terminal_failure_completion` — `abort_all_slots(...)` after a `pre_decode()`/`decode()`/
     `post_decode()` exception (`server-context.cpp:3434-3437,3485-3489,3494-3498`) or the
    `verification_prefix_unfit` path (Section 3.7).
  - In Phase 2, `iteration_completion` is still consumed only by the legacy seam (it is the legacy
    authority's own closure record); nothing transfers to `inference::control`.

### 1.8 Where each term is produced (single-owner)

From `COHORT_BATCHING_CONTROLLER_DESIGN.md:508-521`, applied to Phase 2 under legacy authority:

| Value | Sole Phase 2 producer |
| --- | --- |
| Raw liveness/lifecycle/task/dependency/adapter/capability facts | `server_inference::snapshot_reader` (read-only) |
| Lifecycle-gated `output_committed_count`, pending sampled input | `server_inference::snapshot_reader` (read-only) |
| `reconciled_prompt_coverage`, `contiguous_cap` | `server_execution::prompt_reconciliation_outcome` |
| Actual fresh/replay verification rows | `server_execution::prepared_decode_outcome` / existing replay owner |
| Target advancement, completion, cancellation, replay creation | `server_execution::target_batch_outcome` |
| Pending-work derivation (diagnostic) | `server_inference` comparator (shadow evidence only) |
| Selection, grants, authorization | unchanged legacy planner |

## 2. `server_inference::snapshot_reader` and the diagnostics-only comparator

- `snapshot_reader` is the sole passive, history-free translator
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:509`). Its snapshot is built from slot/task state
  without mutating any owner; the lifecycle-gated progress facts are computed from raw facts and
  discarded after the turn (`COHORT_BATCHING_CONTROLLER_DESIGN.md:351-359`).
- Post-reconciliation snapshot refreshes liveness and raw runtime state; it must not independently
  recalculate reconciliation coverage already reported by the tagged preparation outcome
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:521`).
- The comparator is **diagnostics-only shadow evidence**: projected pending work vs the finalized
  legacy target manifest plus the complete outcome. It never mutates control, fairness cursors,
  slots/runtime, the legacy intent, or the finalized target manifest
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:509,537`). It is compiled behind an
  `LLAMA_COHORT_*` diagnostics switch so no production path can invoke it as a scheduler
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:539` names it a temporary seam deleted with the
  legacy planner in Phase 3).
- No projection is published while an iteration is incomplete, including preparation in flight or
  between `batch_view` values (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:558`).

## 3. Legacy seam catalogue (current tree, exact anchors)

### 3.1 `update_slots` mechanical pump

`tools/server/server-context.cpp:3392-3509`:

| Lines | Legacy content | Phase 2 treatment |
| --- | --- | --- |
| 3392-3404 | `update_slots()` entry, `DEBUG_TIMINGS` block | stays; timing counters remain legacy |
| 3406-3428 | all-idle check; posts `SERVER_TASK_TYPE_NEXT_RESPONSE` | stays; idle fast path yields `zero_work_completion` |
| 3430-3437 | `pre_decode()` + `batch.render()` under try/catch → `abort_all_slots` | becomes legacy-decision + legacy-intent producer call; exception path yields `terminal_failure_completion` |
| 3439-3458 | `GGML_ASSERT(batch.slot_batched \|\| batch.size() == 0)`; aLoRA apply/re-enable; `llama_set_embeddings` | becomes executor `prepare_target_context` mechanics; assertion and adapter semantics byte-for-byte preserved |
| 3460-3499 | decode/view loop: `get_view`, `decode()`, retry on `false`, `post_decode` per view | becomes executor `run_batch_views` under the manifest's retry metadata; loop boundary and error paths preserved |
| 3501-3508 | **pre-landed Phase 5 generating scan** (`try_activate_deferred_mtp`) | stays exactly as-is for Phase 2 (it is a Phase 5 artefact; do not move, gate or delete it) |

### 3.2 Pre-decode maintenance (context shift)

`tools/server/server-context.cpp:3561-3630`: context-shift pass over `SLOT_STATE_GENERATING` slots.
Phase 2 moves this into an executor preparation overload ("maintenance/context shift" in the plan
bullets, `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:511`) without changing any condition or
mutation. Byte-for-byte preserved: 3562-3630 including `slot.release()` branches (3573-3588),
`clear_mtp_archive`/`request_spec_demote` (3607-3608), `seq_rm`/`seq_add` (3609-3610), prompt
rewrite (3614-3626), `slot.truncated = true` (3628).

### 3.3 Generating/draft selection (temporary legacy intent producer)

`tools/server/server-context.cpp:3632-3753`:

- `batch.clear()` 3633; `slot_batched` 3636; `generating`/`drafting` vectors 3638-3639.
- Generating scan 3641-3654: `SLOT_STATE_GENERATING` filter, `can_batch_with` grouping.
- Draft setup 3656-3696: `drafting=false` 3657, `get_n_draft_max()` 3662, partial-draft reuse
  3667-3671, `spec_ckpt.update_pos` 3675-3678, `spec_prompt` copy 3684, draft params assignment
  3686-3693, `drafting.push_back` 3695.
- `common_speculative_draft(spec.get())` 3703.
- Checkpoint creation 3706-3752 (`n_draft_total` 3711, `ckpt.load_dft` 3718, `seq_rm` 3721,
  `ckpt.update_tgt` 3737, `ckpt.update_dft` 3749).
- Sampled/draft row materialization `handle_last_sampled_token(batch)` 3754-3757.

These blocks are *moved verbatim* into the temporary legacy intent producer; no selection logic may
change. The plan's Phase 3 deletion catalogue names this range at
`COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:159-160` (Phase 3 deletes
`server-context.cpp:3629-3745`); Phase 2 must preserve the same source lines byte-for-byte inside
their new location so the Phase 3 deletion can still be executed atomically.

### 3.4 Prompt reconciliation region

`tools/server/server-context.cpp:3766-4342` (prompt loop; post-edit lines 3754-4292 in the older
plan text map to these current lines):

- `3767` continuous-batching gate; `3770-3782` iteration + `can_batch_with` compatibility;
  `3785-3788` `SLOT_STATE_WAIT_OTHER` skip; `3791` `PROCESSING_PROMPT || STARTED` gate.
- STARTED-state mutation begins at 3798-3802 (`t_start_process_prompt`, `state =
  SLOT_STATE_PROCESSING_PROMPT`). **The staged contract requires the legacy planner to name exact
  prompt-reconciliation members before this mutation**
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:512`).
- Cache/checkpoint reconciliation 3820-4102: empty prompt release 3833-3841; logits check 3844-3848;
  split/`n_ubatch`/`n_ctx` checks 3850-3869; cache reset 4033-4039; checkpoint restore 4041-4059;
  `do_reset` 4065-4070; checkpoint erase 4074-4085; `[TAG_PROMPT_LOGITS]` 4088-4094;
  `n_prompt_tokens_cache`/`n_prompt_tokens_processed` 4100-4101; `keep_first(n_past)` 4103.
- MTP prefill-mode prefix handling 4105-4152 (deferred archive prefix/snapshot under
  `common_speculative_mtp_capture_begin`); aLoRA pre-invocation 4157-4169; checkpoint config
  4171-4184; **multimodal direct target execution 4186-4215** (see Section 3.6).
- Prompt-row filling 4220-4279: end-of-chunk 4225-4228, aLoRA stop 4230-4236, embedding/MTP logits
  comment 4238-4240, `batch.add` 4241-4245, `n_prompt_tokens_processed++` 4247, checkpoint breaks
  4250-4278.
- `DONE_PROMPT` transition 4291-4303 (`set_output`, `n_decoded = 0`, `i_batch = batch.size() - 1`,
  `init_sampler`).

Phase 2 splits this into: (a) legacy reconciliation-member naming; (b) mechanical reconciliation via
the executor, which returns one iteration-tagged `prompt_reconciliation_outcome` per member; (c) one
global snapshot; (d) unchanged legacy grant/fill authority, which keeps 4220-4303 verbatim.

### 3.5 Cache/speculative initialization seams

Prompt-cache restore/checkpoint restore and speculative initialization are named executor mechanics
(`COHORT_BATCHING_CONTROLLER_DESIGN.md:1000`). Phase 2 wraps the existing owners without re-implementing
them: cache lookup/restore inside 3820-4102, `init_sampler()` at 4303, `common_speculative_begin`
at 4529 (Section 3.7), `try_activate_deferred_mtp` at 3511-3559 and its prompt-completion call site
4527-4529. No common/runtime code changes.

### 3.6 Multimodal direct target execution

- `server_slot::process_mtmd_chunk()` is `tools/server/server-context.cpp:945-1033`; the helper
  `mtmd_helper_decode_image_chunk()` is invoked at 969-980 and declared at
  `tools/mtmd/mtmd-helper.h:99`.
- Caller for consecutive media runs: the prompt-fill loop at `server-context.cpp:4186-4215`, which
  calls `slot.process_mtmd_chunk(cur_token_idx, n_tokens_out)` at 4200 and counts
  `n_tokens_out` at 4208.
- Phase 2 contract: executor exposes one **exact-task-scoped** multimodal overload; helper-internal
  media chunk aggregation, encoding, batch sizing and target calls remain opaque
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:1011`). The fixture already records this boundary:
  `tests/python/fixtures/cohort_batching_normal_manifest_baseline.json:319`
  (`"kind": "mtmd_helper_decode_image_chunk", "media_helper_batches": "opaque"`).
- **Temporary legacy scoped authorization:** in Phase 2 the legacy planner still owns the decision to
  invoke the multimodal helper for an exact task; the executor requires a temporary legacy scoped
  authorization object passed to that overload. The executor must be structurally unable to select a
  multimodal task or discover media chunks on its own
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:560`).

### 3.7 `decode()` and its error/retry path

`tools/server/server-context.cpp:4347-4470`:

- `decode(int32_t & n_batch, int32_t off, llama_batch & batch_view)` 4347; empty-batch guard
  4350-4360; `has_embd` + spec check 4362-4369; `need_embd_nextn` 4371-4374; `llama_decode`
  4376; `metrics.on_decoded` 4378; error/retry 4380-4428; verification assign
  4434-4437; `common_speculative_process` 4439-4444; parent→child copying 4446-4467.
- **Decode-failure whole-context sweep** `4401-4417`: the error branch releases every processing slot
  and clears prompt/prompt-cache (`deferred-todo-work.md:174-196`). Phase 2 keeps this behavior
  byte-for-byte as the legacy authority's existing terminal cleanup path; classification/ownership of
  that sweep is deferred (`deferred-todo-work.md:181-196`) and remains a Phase 2 known-unknown
  (Section 8). Phase 2 may only route the `verification_prefix_unfit` result into this existing path;
  it must not re-scope or re-own it.
- `common_sampler_sample_and_accept_n` sub-batch compatibility TODO:
  `server-context.cpp:4478-4486` — the post_decode guard throws if a `spec_i_batch` member lies
  outside the current view; the design names this as unresolved
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:665`; `deferred-todo-work.md:125-140`). Phase 2 must keep the
  guard and record the TODO in the plan's risk register; it must not remove or "fix" it.

### 3.8 `post_decode()` outcomes

`tools/server/server-context.cpp:4472-4714`:

- view guard 4474-4486; partial-progress responses 4493-4499; `i_batch` containment 4501-4504;
  embedding/rerank completion 4506-4520; DONE_PROMPT→GENERATING 4522-4530 with MTP activation +
  `common_speculative_begin` 4527-4529; sampling 4540-4574; acceptance 4590-4713 including
  checkpoint replay/rollback 4611-4644 (`spec_is_replay` classification at 4611-4631 per
  `COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:77-79`), `spec_draft = std::move(accepted)` 4653,
  response loops 4689-4708, timings 4710-4712.
- Outcome capture must record exact stream/block/offset identity before `slot.release()`
  (`server-context.cpp:678-707`) erases current-task state. Replay creation from a completing manifest
  remains slot-owned (`COHORT_BATCHING_CONTROLLER_DESIGN.md:996-998`).
- The prompt-completion MTP call site 4527-4529 stays live in Phase 2 (the other pre-landed Phase 5
  edit removed the pre_decode scan and added the 3501-3508 scan);
  `COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:10` notes both sites in the post-edit tree.

### 3.9 SET_LORA and deferred items

- `SERVER_TASK_TYPE_SET_LORA` at `tools/server/server-context.cpp:3313-3325` writes
  `params_base.lora_adapters` ungated (`deferred-todo-work.md:198-213`). Phase 2 **does not** gate it;
  it only records it in the executor seam catalogue as a deferred boundary-gated model mutation
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:528`;
  `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:275`; `deferred-todo-work.md:203-213`).
- Queue drain: `server_queue::start_loop()` drains tasks through `callback_new_task()` then calls
  `callback_update_slots()` (`tools/server/server-queue.cpp:125-208`; `server-context.cpp:1759-1760`
  wires `queue_tasks.on_update_slots`). Phase 2 must not change this drain-then-pump ordering.

## 4. Step-by-step implementation steps

### Build/verification environment (used by every step)

Configure a clean CPU-only build with the flags used by the reference build
`C:\AI\runtimes\llamacpp\builds\llamacpp-yolo-mtp-postdecode-activation-cpu` (its `CMakeCache.txt`
records `CMAKE_BUILD_TYPE:STRING=Release`, Ninja generator, MSVC 14.44 cl.exe, `GGML_CUDA=OFF`,
`GGML_HIP=OFF`, `GGML_VULKAN=OFF`, `GGML_METAL=OFF`, `GGML_SYCL=OFF`, `LLAMA_BUILD_SERVER=ON`,
`LLAMA_BUILD_TESTS=ON`, `LLAMA_BUILD_COMMON=ON`):

```text
cmake -S . -B ..\..\..\..\builds\llamacpp-phase2-cpu -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_CUDA=OFF -DGGML_HIP=OFF -DGGML_VULKAN=OFF -DGGML_METAL=OFF -DGGML_SYCL=OFF ^
  -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TESTS=ON
cmake --build ..\..\..\..\builds\llamacpp-phase2-cpu --target llama-server test-cohort-batching-contracts test-speculative-control
ctest --test-dir ..\..\..\..\builds\llamacpp-phase2-cpu -R "test-cohort-batching-contracts|test-speculative-control" --output-on-failure
```

The `cmake --build` and `ctest` lines are the compile-check gate for every step; each step below
ends with exactly the two lines relevant to what it touched (both must pass before committing that
step). Do not build GPU or run server workloads in Phase 2.

### Step 1 — Reshape Phase 1 DTO headers to the real contract (dormant test target only)

Edits:

- `tools/server/server-execution-outcome.h`: replace `prompt_reconciliation_result` with
  `prompt_reconciliation_outcome { iteration_id iteration; stream_key owner; uint64_t prompt_total;
  uint64_t reconciled_prompt_coverage; int32_t contiguous_cap; }` per
  `COHORT_BATCHING_CONTROLLER_DESIGN.md:431-440`. Keep the header C++17 and value-only; no
  executor/controller includes.
- Add `prepared_decode_outcome`, `target_batch_outcome`, and the completion variant structs in the
  same header (design: `server_execution` owns them; they are producer-owned result DTOs,
  `COHORT_BATCHING_CONTROLLER_DESIGN.md:189-195,431-457`). `prepared_decode_outcome` uses
  `decode_block_origin { FRESH, REPLAY }`, `block_id`, `owner`, `logical_rows`
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:442-451`).
- `tools/server/server-inference-snapshot.h`: split raw vs projected facts so the global snapshot
  is the post-reconciliation snapshot (Section 1.2). Keep `project_current_task` for the dormant
  test but mark the projection inputs as post-reconciliation raw facts; remove `live`/
  `last_logit_pending` reconciliation-result flags from the snapshot surface (they live in the
  manifest rows / outcomes).
- `tests/test-cohort-batching-contracts.cpp`: update assertions that referenced the removed fields
  (the test currently uses `output_committed_count`/`pending_sampled_input` projection at lines
  61-97, unaffected structurally, but must compile against the reshaped headers). Do not add new
  behavior tests yet.

Must remain byte-for-byte: `inference-identity.h`, `inference-profile.h`,
`inference-admission.{h,cpp}`, `inference-batching.{h,cpp}` implementations; the existing
`assess_formation` / `propose_*` semantics.

Authority retained: unchanged legacy planner; nothing in this step reaches the server runtime.

Gate: `cmake --build` of `test-cohort-batching-contracts` and `ctest -R
test-cohort-batching-contracts` pass; `rg -n "prompt_reconciliation_result" tools/server/ tests/`
returns nothing; no server source includes the reshaped headers.

### Step 2 — Add the passive `snapshot_reader` translator (server-local, unused)

Edits:

- New `tools/server/server-inference.{h,cpp}`: `class snapshot_reader` with
  `std::vector<stream_snapshot> read(const std::vector<server_slot> & slots)` (or equivalent const
  view) that materializes raw liveness/lifecycle/task/dependency/adapter/speculative facts from the
  slot fields used by the legacy planner and produces the lifecycle-gated projection per
  `COHORT_BATCHING_CONTROLLER_DESIGN.md:351-359`. No slot/task/runtime mutation, no queue access, no
  static/history state.
- The projection rule: `output_committed_count = gated n_decoded` (zero unless the lifecycle gate
  allows); `pending_sampled_input` only for the sampled-token-owes-one-evaluation case
  (`COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:23-31`).
- No wiring into `server-context.cpp` yet. Compile it into the dormant test target only by adding
  `server-inference.cpp` to `tests/CMakeLists.txt:263-269` beside the existing three sources, and
  include it from a new test translation unit later (Step 12).

Must remain byte-for-byte: all live `tools/server` runtime sources; `tests/test-speculative-control.cpp`
and `common/`, `src/`.

Authority retained: unchanged legacy planner. The reader is a read-only translator with no
side effects — the gate proves it by construction: it has no reference to `server_context_impl`,
`server_queue`, or any mutable slot method.

Gate: build `test-cohort-batching-contracts` (with `server-inference.cpp` added) and
`test-speculative-control`; both pass; `rg -n "snapshot_reader" tools/server/server-context.cpp`
returns nothing.

### Step 3 — Introduce the temporary legacy intent producer (move, not copy)

Edits:

- New `tools/server/server-legacy-intent.{h,cpp}` declaring `make_legacy_intent(...)` and
  `finalize_legacy_target_manifest(...)` with the exact responsibilities of
  `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:539` (temporary seam, deleted atomically in Phase 3).
- Move `tools/server/server-context.cpp:3561-3630` (context-shift maintenance) and
  `3632-3757` (generating/draft selection + `handle_last_sampled_token` materialization) into
  `make_legacy_intent` as private helpers. The moved code keeps every comparison, assert and logging
  line identical; only the surrounding function signature changes.
- The producer records the intent's `iteration_id` (allocated by the caller, Step 6), the ordered
  draft/replay block descriptors (fresh vs replay per `spec_draft` non-empty at 3667-3671 and
  `spec_is_replay` at 4611-4631), and the reserved `1 + effective draft maximum` per speculative
  candidate (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:528`; effective maximum from every
  implementation eligible for the member after scheduler caps, not hard-coded MTP `n_max` —
  `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:529`).

Must remain byte-for-byte: the moved lines themselves (verbatim source relocation); the prompt
region 3766-4342 and `decode()`/`post_decode()` bodies in `server-context.cpp` (they call the
producer next); `common/speculative.*`, sampling, cache/checkpoint, `llama_decode`.

Authority retained: the legacy planner still *owns* selection; the producer only relocates it.
Phase 3 will delete the producer's scheduling interpretation (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:599-602`),
which is exactly why it must be one mechanical unit now.

Gate: build `llama-server` (CPU) and both tests; `rg -n "SLOT_STATE_GENERATING" tools/server/server-context.cpp`
still shows the pre-move line count minus the moved blocks, and `rg -n "get_n_draft_max|common_speculative_draft" tools/server/`
shows exactly one definition each (no duplicated copy). NORMAL manifest fixture diff empty: run
the fixture comparator (Section 6, gate command) — outputs must equal the Phase 0 fixture modulo
`iteration_id` population.

### Step 4 — Staged reconciliation: legacy names members before STARTED mutation

Edits:

- Split the prompt region `tools/server/server-context.cpp:3766-4342` into: (a) member naming pass
  before 3798-3802 (`state = SLOT_STATE_PROCESSING_PROMPT`); (b) mechanical reconciliation
  (3820-4102 cache/checkpoint/speculative restoration) returning one
  `prompt_reconciliation_outcome` per named member; (c) one global snapshot publication; (d) the
  unchanged grant/fill tail 4220-4303.
- The member naming pass must run exactly the legacy predicate on
  `SLOT_STATE_PROCESSING_PROMPT || SLOT_STATE_STARTED` (3791) plus the `can_batch_with` grouping
  (3780-3782), but must not mutate any slot until every member is named
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:512`).
- The reconciliation outcome producer records `prompt_total` (task `n_tokens()`), the reconciled
  coverage (post-restore `n_prompt_tokens_cache`/processed coverage), `contiguous_cap` (legal
  contiguous grant size per the existing fill loop bounds), all tagged with the current
  `iteration_id` and exact `stream_key`.
- Every mutably prepared live prompt stream must receive at least one legal grant in the resulting
  target manifest (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:527`);
  redistribution may occur only within the already committed prompt-preparation set
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:661`).

Must remain byte-for-byte: the grant/fill tail 4220-4303 and the `DONE_PROMPT` transition
4291-4303; all cache/checkpoint/speculative owner mechanics inside (b); the multimodal sub-block
4186-4215 (see Step 8 before touching it).

Authority retained: unchanged legacy authority chooses/grants rows after the global snapshot
(`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:513`). No target work, admission sweep, phase
transition, fairness advancement, or unrelated scheduling decision may occur between stages
(`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:515`).

Gate: build + both tests; a temporary trace assertion (diagnostics-only, compiled in) proves
reconciliation outcomes for all named members exist before the first grant call; fixture diff empty.

### Step 5 — Extract the `server_execution::executor` façade (preparation overloads)

Edits:

- New `tools/server/server-execution.{h,cpp}` with the overload set named in
  `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:511`:
  - `prepare_maintenance` — moved context-shift pass (Step 3) unchanged;
  - `prepare_drafts` — the moved `common_speculative_draft`/checkpoint sequence (Step 3);
  - `prepare_prompt_reconciliation` — Step 4 mechanical stage;
  - `prepare_cache_speculative_init` — thin wrapper over existing cache restore/`init_sampler`/
    `common_speculative_begin` owners (no re-implementation); in Phase 2 the prompt-completion
    `common_speculative_begin` call site stays inline at 4527-4529 and is only named as a seam, not
    relocated (the pre-landed Phase 5 scan at 3501-3508 already owns the other call site);
  - `prepare_target_context` — the aLoRA/embedding pre-decode block 3439-3458.
- Each overload takes a `const legacy_authority_token &` (temporary legacy planner authorization) and
  returns the exact iteration-tagged outcome. The interface is mechanical and does not yet imply a
  control commit (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:511`).
- Wire `update_slots()` (3392-3509) to call these in order; keep the try/catch boundaries and
  `abort_all_slots` behavior identical.

Must remain byte-for-byte: every moved line; `decode()` 4347-4470 and `post_decode()` 4472-4714
are not yet touched by the executor (only called through it); `llama_decode` and speculative
call boundaries.

Authority retained: the legacy planner still selects; the executor is mechanical under the legacy
authority token — it cannot select a stream, block, or command category
(`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:559`).

Gate: build + both tests; fixture diff empty; `rg -n "executor" tools/server/server-context.cpp`
shows calls only from `update_slots()` and `pre_decode()`'s replacement — no policy branch uses it.

### Step 6 — Monotonic `iteration_id` in the pump and outcomes

Edits:

- Add one `uint64_t`/`iteration_id` counter member to `server_context_impl`, incremented at the top
  of the settled turn (after the idle fast path and before `pre_decode()`), reused across the whole
  turn and stamped on every outcome produced in that turn.
- No per-slot or per-view ID; one lineage per turn (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:67`).
- Outcomes produced in `post_decode()` (release/replay/completion) capture the turn ID before
  `slot.release()`; the `target_batch_outcome` aggregates them under the same ID
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:453-457,996-998`).

Must remain byte-for-byte: all scheduling branches; the ID is additive bookkeeping only.

Authority retained: unchanged legacy planner; the counter is legacy-seam-owned, not control-owned.

Gate: build + both tests; fixture diff equal modulo populated `iteration_id`
(`fixture iteration_note`); a debug assertion proves one ID per `update_slots()` turn with no gaps
in the counter (monotonic).

### Step 7 — Finalize the target manifest with block offsets and retry metadata

Edits:

- `finalize_legacy_target_manifest()` (Step 3) emits, after the prompt grant/fill tail, the
  manifest value: ordered block rows with per-block byte/logical offsets, output/logit/NextN
  membership per block, the contiguous verification prefix, and retry metadata preserving the
  complete prepared union in the first processed view
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:532`;
  `COHORT_BATCHING_CONTROLLER_DESIGN.md:602,665`).
- Replay blocks are mandatory known-size prefix members placed before fresh drafts and never
  drafted again (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:532`);
  replay pricing uses `replay_token_count`/`replay_rows` semantics per
  `COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:77-79` and is priced before fresh candidates
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:637-638`).
- Retry metadata allows `n_batch` halving for prompt-tail rows only
  (`server-context.cpp:4421-4428`); the verification prefix remains indivisible
  (`COHORT_BATCHING_CONTROLLER_DESIGN.md:667`).

Must remain byte-for-byte: the actual row-add sequence (offsets are derived from it, not
recomputed); the retry loop 3460-3499; the `spec_i_batch` guard 4478-4486.

Authority retained: unchanged legacy planner decides membership; the manifest only records the
decision and its geometry.

Gate: build + both tests; fixture diff empty; a diagnostic-only check asserts offsets are monotonic
and prefix-consistent for a synthetic 65-row ngram block
(`tests/test-cohort-batching-contracts.cpp` — model-free DTO test).

### Step 8 — Executor target/external overloads: batch construction, retry views, complete outcome

Edits:

- `server_execution::executor` gains `execute_target_manifest(const target_manifest &, const
  legacy_authority_token &)` which builds the exact `server_batch`, runs the decode/view loop
  (3460-3499) under the manifest's retry metadata, and accumulates every `batch_view` result under
  the turn's `iteration_id` (`COHORT_BATCHING_CONTROLLER_DESIGN.md:657`).
- Capture exact stream/block/offset identity and per-stream completion/cancellation/replay facts
  before `slot.release()`/`reset()` (678-707); finish mandatory post actions; publish one complete
  `target_batch_outcome` after all views settle (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:536`;
  `COHORT_BATCHING_CONTROLLER_DESIGN.md:658`).
- `external_execute_mtmd(const exact_task_scope &, const legacy_scoped_mtmd_authorization &)` wraps
  the exact-task-scoped multimodal path 945-1033/4186-4215. The authorization is temporary and
  legacy-issued; without it the overload refuses to execute (gate command below).
- On `verification_prefix_unfit`, return the typed result and route into the existing terminal
  cleanup/error path (4401-4417) without slicing/dropping/despeculating/restoring/replanning
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:534`).

Must remain byte-for-byte: `decode()`/`post_decode()` internals; helper-internal chunk aggregation/
encoding/batch sizing (opaque); `llama_decode` call boundary.

Authority retained: the legacy planner remains the sole scheduler; the executor cannot discover an
unlisted stream or select a command category (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:559`).

Gate: build + both tests; fixture diff empty; `rg -n "mtmd" tools/server/server-execution.*` shows
the helper is reachable only through the authorized overload; a dormant unit test proves the
un-authorized overload path returns refusal without touching slots.

### Step 9 — Complete-manifest closure and `iteration_completion`

Edits:

- The pump assembles one `iteration_completion` only after every `batch_view` and mandatory post
  action settles (`COHORT_BATCHING_CONTROLLER_DESIGN.md:628`): for target turns the complete
  `target_batch_outcome`; for admission-only, zero-work, and terminal-failure turns the explicit
  variants (Section 1.7).
- After the completion, `update_slots()` refreshes the snapshot (the pump contract's final stage:
  snapshot → legacy decision → exact dispatch → complete outcome → refreshed snapshot,
  `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:510`).
- No projection may be published between `batch_view` values or while preparation is in flight
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:558`).

Must remain byte-for-byte: the existing queue drain/reinsertion and deferred-task promotion order
(`tools/server/server-queue.cpp:125-208`); the generating scan 3501-3508 (pre-landed Phase 5 edit);
the prompt-completion MTP site 4527-4529.

Authority retained: unchanged legacy planner consumes the completion (as its own closure record);
no control consumption exists yet.

Gate: build + both tests; fixture diff empty; diagnostic-only trace proves exactly one
`iteration_completion` per settled turn and zero mid-view completions.

### Step 10 — Diagnostics-only progress/pending-work comparator (shadow evidence)

Edits:

- New `tools/server/server-progress-comparator.{h,cpp}` (server-local, diagnostics-only) that
  computes projected pending work from the post-reconciliation snapshot and compares it with the
  finalized legacy target manifest plus the complete `target_batch_outcome`. It returns a report
  struct; it must not mutate slots, runtime, legacy intent, or the manifest
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:537`).
- Compiled in only under a diagnostics switch (e.g. `LLAMA_COHORT_DIAGNOSTICS`) so no production
  path can apply it as a scheduler; keep it out of the default `llama-server` link if the switch is
  off, or make it a no-op TU. Decide the exact switch name in Step 10 and document it here:
  `LLAMA_COHORT_DIAGNOSTICS` (UNVERIFIED choice; the plan only requires a non-default switch).
- The comparator never publishes a projection while an iteration is incomplete
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:558`).

Must remain byte-for-byte: all server runtime behavior with the switch off; with the switch on,
only diagnostic output may differ.

Authority retained: unchanged legacy planner; the comparator is shadow evidence, never an applying
scheduler (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:537-539`).

Gate: build with and without `-DLLAMA_COHORT_DIAGNOSTICS=ON` (two builds); both tests pass;
`rg -n "comparator" tools/server/` shows no call site that mutates state (only report emission);
fixture diff empty in both builds.

### Step 11 — Prepared-live-stream invariants (no carry-over)

Edits (hardening inside Steps 3-10's seams, verified as one commit):

- Every `prepared_decode_outcome` appears in the same iteration's finalized legacy target manifest;
  do not exercise the existing reuse capability (3667-3671) as a scheduler carry-over policy
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:530`).
- Bulk-draft only the selected set (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:528`); actual
  shorter drafts may free NORMAL prompt capacity but never trigger opportunistic preparation of
  another speculative member (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:241`).
- A prepared speculative stream is never omitted from its iteration's target manifest
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:566`).
- Output/logit and NextN rows match target-manifest block membership
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:567`).

Must remain byte-for-byte: the reuse path itself (it is legacy behavior, just not a scheduler
policy); the replay classification 4611-4631; output/logit assignment 4297-4303.

Authority retained: unchanged legacy planner; the invariant is asserted by diagnostics, not
enforced by the executor (no authority transfer).

Gate: build + both tests; fixture diff empty; diagnostic assertion runs in the dormant test target
with synthetic prepared/replay sets and proves the four invariants.

### Step 12 — Extend/reshape the dormant test surface (model-free)

Edits:

- `tests/test-cohort-batching-contracts.cpp`: add model-free tests for (a) the comparator: projected
  pending work vs finalized manifest + complete outcome (including an in-flight iteration must not
  publish a projection); (b) contract extraction: monotonic iteration IDs, lineage-tagged
  `prepared_decode_outcome`/`prompt_reconciliation_outcome`, complete-outcome capture ordering,
  completion variants; (c) manifest offsets/retry metadata geometry (including the 65-row atomic
  ngram block case from the plan: `1 + effective draft maximum` = 65 for `n_max=64` ngram-mod,
  `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:230`); (d) `verification_prefix_unfit` routing
  to the terminal path.
- Add `server-inference.cpp`, `server-execution.cpp`, `server-legacy-intent.cpp`,
  `server-progress-comparator.cpp` to the `test-cohort-batching-contracts` sources in
  `tests/CMakeLists.txt:263-269` (these TUs must be compilable without a model; keep them
  free of `server-context.cpp`/`server_queue` includes where possible, or provide model-free test
  shims only in the test target).
- Keep `tests/test-speculative-control.cpp` passing — it builds against the modified tree
  (`tests/CMakeLists.txt:262`); do not alter its semantics.

Must remain byte-for-byte: `tests/test-speculative-control.cpp` and all Phase 1 proposal tests'
observable assertions except where the reshaped headers (Step 1) strictly require renames.

Authority retained: unchanged legacy planner; tests exercise the dormant contracts only.

Gate: `ctest -R "test-cohort-batching-contracts|test-speculative-control" --output-on-failure`
passes; `cmake --build --target llama-server` passes; fixture diff empty.

### Step 13 — Final Phase 2 gate audit (Section 6) and rollback dry-run

Edits: none (documentation of the audit output committed with the plan's completion; workers run
all Section 6 commands and record results).

Must remain byte-for-byte: the audited tree itself.

Authority retained: unchanged legacy planner — final proof via the grep gates below.

Gate: every command in Section 6 passes; Section 9 rollback procedure re-applied in a scratch
worktree without touching the main branch.

## 5. Non-server workstream statement

No changes to `common/`, `src/`, backend, or `llama_decode`
(`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:541-545`; `COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:215`).
Call boundaries are byte-for-byte preserved:

- `common_speculative_draft` (`tools/server/server-context.cpp:3703`), `common_speculative_process`
  (4439), `common_sampler_sample_and_accept_n` (4590 region), `common_speculative_begin` (4529),
  `common_speculative_mtp_capture_begin`/`backfill` (3532-3556), checkpoint/spec restore (3718,
  3737, 3749, 4041-4059) — wrapper-only, no signature/behavior change.
- `llama_decode` (`server-context.cpp:4376`), `llama_set_embeddings`/`llama_set_embeddings_nextn`
  (3457, 4373), `llama_memory_seq_rm`/`seq_add` (3609-3610), `mtmd_helper_decode_image_chunk`
  (969) — untouched.
- `common/` speculative preparation/verification, sampling, cache/checkpoint implementations,
  `llama_decode()`, and backend behavior byte-for-byte at their existing call boundaries
  (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:541-545`).

Verification: `git diff --stat HEAD -- common/ src/` is empty for every Phase 2 commit; the
fixture's recorded source hashes for `common/speculative.{h,cpp}`, `common/sampling.cpp`,
`src/llama-context.cpp`, `src/llama-batch.cpp`
(`tests/python/fixtures/cohort_batching_normal_manifest_baseline.json:23-32`) are re-checked
before the final gate (UNVERIFIED as authoritative byte hashes until re-run at Step 13 — the fixture
was captured against an earlier tree, `COHORT_BATCHING_PHASE0_NORMAL_BASELINE.md:7-14`).

## 6. Phase 2 gate checklist (concrete verification commands)

The architecture gate bullets are `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:553-568`. Run all
commands from the working-tree root, with the build dir from Section 4:

1. **NORMAL target manifests equal Phase 0 fixtures.**
   `ctest -R test-cohort-batching-contracts --output-on-failure` (the comparator test in Step 12
   asserts fixture equality modulo `iteration_id`); plus
   `python tools/server/tests/compare_phase2_manifest.py` if such a helper is added in Step 12
   (otherwise a model-free fixture-diff test lives in `test-cohort-batching-contracts` — the exact
   helper name is a worker choice, UNVERIFIED as to whether upstream ships one). Must pass in both
   diagnostics builds.
2. **Contract backed by real producer/executor boundary.**
   `rg -n "make_legacy_intent|finalize_legacy_target_manifest" tools/server/server-context.cpp` shows
   the calls; `rg -n "prepared_decode_outcome|prompt_reconciliation_outcome" tools/server/` shows
   producer-owned definitions and real-seam call sites, not a simulated Phase 1 controller.
3. **Translator/comparator cannot mutate runtime.**
   `rg -n "snapshot_reader|comparator" tools/server/*.cpp` — audit every call site: only const
   reads and report emission; plus the dormant test asserts no slot/queue mutation occurs.
4. **Reconciliation complete before snapshot/grants.**
   `rg -n "prompt_reconciliation_outcome" tools/server/server-context.cpp` — the outcome producer
   precedes the first `batch.add` prompt call in the source order (Step 4 ordering); dormant test
   re-verifies with a traced model-free fake.
5. **Projected work explains every finalized legacy row.**
   `LLAMA_COHORT_DIAGNOSTICS=ON` build; the comparator test asserts each manifest row maps to one
   pending-work item or exact external operation (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:557`).
6. **No projection published mid-iteration.**
   Dormant test asserts the comparator refuses to publish between `batch_view` values / while
   preparation is in flight (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:558`).
7. **Executor cannot discover unlisted streams or select command categories.**
   `rg -n "execute_target_manifest|external_execute_mtmd" tools/server/server-execution.*` — the
   executor accepts only the manifest/scope plus the legacy authorization token; dormant test proves
   refusal without the token.
8. **Multimodal requires temporary legacy scoped authorization.**
   `rg -n "mtmd" tools/server/server-execution.*` — the only helper path is inside the authorized
   overload; dormant test proves the un-authorized path refuses.
9. **Prompt preparation cannot mutate an uncommitted candidate.**
   `rg -n "SLOT_STATE_STARTED" tools/server/server-context.cpp` — the state mutation occurs only
   after the member-naming pass (Step 4); dormant test verifies the fake member is untouched before
   naming completes (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:561`).
10. **Retry keeps the complete verification prefix in the first view.**
    `rg -n "verification_prefix|spec_i_batch" tools/server/server-execution.* tools/server/server-context.cpp` —
    the retry metadata + the 4478-4486 guard are intact; dormant test uses a 65-row ngram block and
    prompt-tail-only partitioning (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:562-563,565`).
11. **`verification_prefix_unfit` → existing terminal path.**
    `rg -n "verification_prefix_unfit" tools/server/` — the typed result routes to the existing
    cleanup/error path (4401-4417), with no slicing/dropping/despeculating/restoring/replanning
    (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:564`).
12. **Prepared speculative stream never omitted.**
    `rg -n "prepared_decode_outcome" tools/server/server-execution.*` — the finalize step (Step 11)
    asserts every outcome appears in the same iteration's manifest
    (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:566`).
13. **Output/logit and NextN rows match block membership.**
    `rg -n "set_output|spec_i_batch|i_batch" tools/server/server-context.cpp` — 4297-4303 and
    4478-4486 membership indexing is unchanged; dormant test checks manifest block offsets against
    synthetic output rows (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:567`).

## 7. Phase 2 authority proof (per step)

Each step above names the retained legacy authority; the invariant is the architecture rule
(`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:25-34`):

```text
admission/batching component calculates an exact proposal
    -> inference::control emits the corresponding exact command
    -> server adapter applies mechanically
    -> tagged outcome refreshes facts at a quiescent boundary
```

In Phase 2 the "control emits" leg is explicitly *not yet present*: the legacy planner substitutes
for the command emission. To keep this provable, every new component must satisfy:

- `server_inference` (translator/comparator): no mutable slot/task/queue/runtime reference, no
  history/static state, no applying API.
- `server_execution` (executor): only the manifest/scope plus the legacy authorization token as
  inputs; no slot scanning to discover work; no command-category selection.
- legacy intent producer: the moved legacy selection, unchanged; it records intent, never grants.

Proof commands are listed per gate in Section 6; the plan's own authority-transfer prohibition is
`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:493-495` ("None. A single legacy planner remains the
sole runtime scheduling authority.").

## 8. Risks and known unknowns

1. **Pre-landed Phase 5 scan interaction** — `tools/server/server-context.cpp:3501-3508` is the
   pre-landed post-decode generating scan; the second legacy MTP call site remains live at
   4527-4529. Phase 2 must not move, gate, or delete either; re-verify both against the final
   Phase 5 design when Phase 5 lands (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:9`;
   `COHORT_PROGRESS_DEBT_CONSOLIDATED_DELTA.md:10`).
2. **`common_sampler_sample_and_accept_n` sub-batch compatibility TODO** —
   `tools/server/server-context.cpp:4478-4486` (design cites the TODO at
   `COHORT_BATCHING_CONTROLLER_DESIGN.md:665`; deferred work at `deferred-todo-work.md:125-140`).
   Phase 2 keeps the guard; do not "fix" it. UNVERIFIED whether any view geometry in Phase 2 can
   trigger it with the new manifest metadata; workers re-verify with the dormant geometry tests.
3. **Decode-failure whole-context sweep deferred** — the 4401-4417 sweep is preserved verbatim;
   its classification/ownership is deferred (`deferred-todo-work.md:174-196`) and is a Phase 2
   known-unknown, not a Phase 2 change.
4. **SET_LORA deferred** — the ungated `SERVER_TASK_TYPE_SET_LORA` write at 3313-3325 is preserved;
   boundary gating is deferred to the model-mutation classification
   (`COHORT_BATCHING_CONTROLLER_DESIGN.md:528`;
   `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:275`; `deferred-todo-work.md:198-213`).
5. **Fixture hashes are historical** — the fixture's recorded `source_hashes_sha256`
   (`tests/python/fixtures/cohort_batching_normal_manifest_baseline.json:23-32`) were captured
   against an earlier tree; re-verify before final gate (UNVERIFIED as byte hashes of the current
   tree).
6. **Working-tree line drift** — the plan's older anchors (e.g. pre_decode at 3543-4331,
   decode at 4335-4458, post-decode at 4460-4701, multimodal at 945-1020,
   `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:499-503`) are pre-edit; this plan's Section 3
   anchors are the current tree and must be re-checked after every intermediate commit.
7. **`n_ubatch` physical capacity** — never participates in reservation or member selection
   (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:243`); the prompt-split checks at 3850-3869 use
   `n_ubatch` as legacy behavior and must not be "fixed" during the refactor.
8. **`verification_prefix_unfit` authority** — Phase 2 routes it to the existing terminal path;
   Phase 3 transfers the unfit decision to control (`COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:534`).
   Until then the executor must not slice/drop/despeculate/restore/replan.

## 9. Rollback (revert Phase 2 while Phase 1 remains dormant)

Per `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:569-571` and
`COHORT_ROLLBACK_RUNBOOK.md:96-106`:

```text
# from the working tree root
git status --porcelain          # verify only Phase 2 files are touched
git diff --stat HEAD            # verify no common/ src/ changes

# Option A — the runbook's stated operation (revert the Phase 2 commit(s)):
git revert <phase2-commit...>   # undo mechanical extraction; restore update_slots()

# Option B — drop the uncommitted Phase 2 work entirely:
git checkout -- tools/server/server-context.cpp tools/server/server-queue.cpp \
  tools/server/server-task.cpp tests/CMakeLists.txt tests/test-cohort-batching-contracts.cpp
git clean -fd -- tools/server/server-inference.cpp tools/server/server-execution.cpp \
  tools/server/server-legacy-intent.cpp tools/server/server-progress-comparator.cpp

# re-run the runbook Phase 2 rollback verifications:
rg -n "snapshot_reader|server_execution::executor|iteration_id" tools/server/server-context.cpp
rg -n "prepared_decode_outcome|prompt_reconciliation_outcome|target_manifest" tools/server/
rg -n "iteration_completion" tools/server/
```

Expected results: `update_slots()` is the single monolithic pre-extraction body; no iteration-tagged
outcome types reach the server pump; no iteration-closure boundary exists; legacy NORMAL behavior is
byte-for-byte identical to the Phase 0 baseline (`COHORT_ROLLBACK_RUNBOOK.md:102-106`). Phase 1's
dormant contracts stay landed (they are the pre-Phase 2 state), and the pre-landed Phase 5 scan edit
is outside Phase 2 rollback scope but must be left untouched by the revert.

## 10. Source-reference appendix (current tree)

- Phase 2 architecture section: `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:489-572`.
- Mechanical dispatch point: `COHORT_BATCHING_CONTROLLER_DESIGN.md:614-628`.
- Canonical vocabulary: `COHORT_BATCHING_CONTROLLER_DESIGN.md:589-611`.
- Iteration-planning contract (steps 1-13): `COHORT_BATCHING_CONTROLLER_DESIGN.md:630-659`.
- Executor/adapter authority table: `COHORT_BATCHING_CONTROLLER_DESIGN.md:202-221`.
- Progress/debt facts: `COHORT_BATCHING_CONTROLLER_DESIGN.md:351-370`.
- Command matrix: `COHORT_BATCHING_CONTROLLER_DESIGN.md:494-506`.
- Complete-manifest closure: `COHORT_BATCHING_CONTROLLER_DESIGN.md:628`.
- Legacy seams (current tree): Section 3 of this plan.
- Dormant Phase 1 surface: `tools/server/inference-identity.h`,
  `tools/server/inference-profile.h`, `tools/server/inference-control.h`,
  `tools/server/server-inference-snapshot.{h,cpp}`, `tools/server/inference-admission.{h,cpp}`,
  `tools/server/inference-batching.{h,cpp}`, `tools/server/server-execution-outcome.h`.
- Dormant test surface: `tests/test-cohort-batching-contracts.cpp`, `tests/CMakeLists.txt:263-276`.
- Queue/task files: `tools/server/server-queue.{h,cpp}`, `tools/server/server-task.{h,cpp}`.
