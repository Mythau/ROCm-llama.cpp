# Cohort Progress/Debt First-Pass Findings

Status: components A, B, and C completed and reconciled. This document proposes an architecture delta for review. It does not authorize implementation, builds, runtime tests, commits, or edits to the active controller design and phased implementation plan.

Checklist: `COHORT_PROGRESS_DEBT_FIRST_PASS_CHECKLIST.md`.

## Decision from the first pass

The current branch has no safe singular stored computed-token frontier. The controller must not add one.

Project committed logical progress ephemerally at a quiescent scheduling boundary as the current-task tuple:

```text
(reconciled prompt commitment, accepted output count)
```

Keep four domains distinct:

```text
committed logical progress
    monotonic for one live {slot_id, task_id}

pending target debt
    prompt/reconciliation, sampled token, fresh verification, mandatory replay

prepared/speculative extent
    may expand or retract through drafting, verification and rollback

physical execution state
    prompt representation, KV positions, checkpoints, cache and MTP archive
    may restore, shift, shrink, evict or rebuild
```

Only the controller's global scheduling phase remains persistent policy state. Per-member progress and debt are rebuilt from authoritative owners at every decision boundary and discarded.

## Source proof

| Source fact | Finding | Evidence |
| --- | --- | --- |
| `slot.prompt.tokens` | Not logical progress: it is extended before target execution, contains sampled/draft rows, retracts after verification, changes under context shift, and may survive release for cache reuse | `tools/server/server-context.cpp:638-675`, `3543-3610`, `4210-4235`, `4612-4629`, `4667-4674`, `678-705` |
| Reconciled local `n_past` | Exact usable current-request prompt prefix exists transiently after STARTED reconciliation and before grants | `tools/server/server-context.cpp:3808-4091` |
| `n_prompt_tokens_processed` | Accounting metric, not committed progress: it advances during batch construction before target execution | `tools/server/server-context.cpp:4084-4091`, `4196`, `4210-4235` |
| `n_decoded` | Monotonic accepted-output count only after prompt completion; stale during a newly reused slot's STARTED/PROCESSING_PROMPT lifecycle | `tools/server/server-context.cpp:452-492`, `4279-4291`, `4543`, `4686` |
| `sampled` | Last accepted/output-counted token that still owes target evaluation; lifecycle identity and current runtime state gate its meaning | `tools/server/server-context.cpp:2290-2294`, `638-675`, `4671` |
| `spec_draft`, `spec_i_batch`, `spec_ckpt`, `spec_is_replay` | Existing speculative runtime owns prepared extent, row mapping, rollback and replay classification | `tools/server/server-context.cpp:3650-3745`, `4584-4675` |
| Target/draft memory positions | Physical diagnostics and alignment inputs, not monotonic request progress | `include/llama.h:732-794`; `tools/server/server-context.cpp:3543-3610`, `4005-4058`, `4620-4628` |
| Prompt checkpoints/cache | Physical/resident capability; STARTED reconciliation decides the usable prefix for the newly attached request | `common/common.h:1138-1195`, `common/common.cpp:2115-2243`, `tools/server/server-task.cpp:1675-1940` |
| Deferred MTP archive | Physical alignment state; backfill requires target `pos_max == archive.pos_end`, so target-only advancement invalidates later activation | `common/speculative.cpp:1539-1624`, `tools/server/server-context.cpp:3523-3533` |

No new persistent authoritative counter is proven necessary. The structural requirement is to expose reconciled `n_past` as an ephemeral fact at the stable post-reconciliation, pre-grant seam.

## Proposed ephemeral facts

Semantic contract; exact C++ representation remains an implementation detail:

```cpp
struct stream_progress_facts {
    cohort_member member;

    bool independently_runnable;
    bool progress_reconciled;

    uint64_t prompt_total;
    uint64_t prompt_committed;
    uint64_t accepted_output_count;

    bool sampled_token_pending;

    bool mandatory_replay;
    size_t replay_token_count;

    uint32_t speculative_eligible_mask;
    uint32_t stateful_synchronized_mask;
    bool speculative_cycle_active;
};
```

Physical target/draft positions may accompany this projection as diagnostics/capability facts. They are not members of committed logical progress and never decide cohort barrier completion.

Eligibility and compatibility remain orthogonal facts:

- Exact task/slot liveness and independently runnable status.
- Adapter signature and aLoRA status.
- Immutable cohort speculative profile or current NORMAL speculative eligibility.
- Cache/preparation capability.
- Multimodal/exclusive, embedding and rerank classification.

`WAIT_OTHER` exposes dependency identity but no independently runnable target debt. After parent state copying, the refreshed projection exposes each activated child as its own runnable stream.

## Derived debt model

Debt is a derived set, not another mutually exclusive persistent state enum.

| Debt | Derivation | Row pricing |
| --- | --- | --- |
| Prompt/reconciliation | Runnable text member has unsatisfied prompt coverage or mandatory logits-producing prompt reconciliation | Contiguous prepared legal grant |
| Sampled token | Accepted sampled token still requires target evaluation and no prepared block supersedes it | One ordinary row or worst-case speculative reservation envelope before drafting |
| Fresh verification | Selected fresh drafting has produced a sampled-plus-proposal block | Exact actual atomic block |
| Mandatory replay | Existing runtime reports `spec_is_replay` and retained accepted replay material | Known actual atomic block, before fresh candidates |
| No runnable target debt | No authorized target work is currently owed | Zero |

Precedence prevents double pricing:

```text
mandatory replay
    supersedes standalone sampled/fresh classification

prepared fresh verification
    supersedes standalone sampled-token debt

sampled-token debt
    -> worst-case reservation
    -> control selects exact fresh member set
    -> bulk draft selected set only
    -> refreshed projection reports exact verification debt
```

Logical progress does not make proposals free. Speculative expansion may retract, while sampled-plus-proposal verification consumes real logical target rows.

## Controller policy predicates

| Controller phase | Authorized text debt | Boundary predicate |
| --- | --- | --- |
| `NORMAL` | Mandatory replay first; selected sampled/fresh verification next; genuine residual logical capacity to contiguous prompt grants | Existing entry/hysteresis policy; enter DRAIN when incumbent decode-family debt must drain, otherwise FORM when compatible |
| `COHORT_DECODE_DRAIN` | Replay, sampled and verification debt only; prompt debt remains visible but held | INTERMISSION at `R <= X`; FORM when `R > X` and no runnable decode-family debt remains |
| `COHORT_FORM` | None | Freeze exact membership/profile or return to NORMAL at/below `X` |
| `COHORT_PREFILL` | Prompt/reconciliation debt only; sampled/decode debt remains visible but held | Barrier closes when every live exact member has zero prompt debt |
| `COHORT_DECODE` | Replay, sampled and verification debt only | INTERMISSION at `R <= X`; otherwise continue for live members |
| `COHORT_INTERMISSION` | No text debt; only the selected exact multimodal task's committed work | Existing one-task survivor rules |

`R` remains the number of eligible independently runnable attached cohort text streams. It is not a debt-item count.

Early prompt completion becomes:

```text
final prompt outcome
    -> first output token accepted exactly once
    -> refreshed projection has zero prompt debt plus sampled-token debt
    -> COHORT_PREFILL withholds sampled debt
    -> zero-prompt-debt barrier closes
    -> COHORT_DECODE pays sampled debt exactly once
```

The existing `SLOT_STATE_GENERATING` mutation may remain genuine slot/response lifecycle mechanics. It ceases to be a scheduling-policy predicate.

## Manifest lineage

One transient committed iteration manifest must govern the entire turn:

```text
fact snapshot
    -> control opens one manifest and binds exact preparation membership
    -> execution performs only authorized preparation
    -> actual prepared sizes finalize layout without changing membership
    -> retry views mechanically project the same manifest
    -> target execution, post-decode and outcomes consume the same manifest
```

- Preparation cannot add an unselected member.
- Final layout cannot omit prepared live work.
- Shorter drafts change row extent, not selected membership or scheduling identity.
- Retry cannot reinterpret or reschedule membership.
- The complete verification prefix remains indivisible under current post-decode mechanics.
- Output/logit limits, NextN, verification, rollback, replay and outcomes retain the committed membership and offsets.

This manifest is transient execution authority, not another persistent policy lifecycle. No new monotonic manifest ID is required by the architecture.

## Authority result

| Owner | Retained authority | Projection role |
| --- | --- | --- |
| Slot/task | Lifecycle, request prompt/history, sampled token, completion/release | Source facts only |
| Speculative runtime/slot | Drafts, verification indices, checkpoint, acceptance, rollback and replay | Prepared/replay facts and actual row cost |
| Cache/checkpoint/memory | Restore, eviction, context shift and physical positions/state | Capability, reconciled coverage and diagnostics |
| `server_queue` | Ordering, leases and cancellation visibility | Candidate facts only |
| `server_inference` | Mechanical source-to-fact translation | Ephemeral projection with no history |
| `inference::batching` | Pure debt derivation, pricing, fair selection and prompt grants | Proposal only |
| `inference::control` | Six global phases, cohort identity/membership/profile/cursor and final authorization | Sole policy commit; no member frontier/debt mirror |
| `server_execution` | Authorized preparation/execution and outcome reporting | Mechanical application; no work discovery |

The only permitted temporary duplication is Phase 2 comparison between the legacy categorical planner and a non-applying ephemeral projection. Phase 3 must atomically delete legacy categorical scheduling interpretation when progress/debt-based NORMAL authority takes over.

## Phased-plan delta

| Phase | Required delta |
| --- | --- |
| 0 | Capture raw authoritative inputs, reconciled progress tuple, pending/prepared facts, legacy classification, manifest and correlated outcome. Projection remains shadow evidence only. |
| 1 | Define dormant ephemeral facts/debt derivation and deterministic tests. Store none of it in control. |
| 2 | Extract one mechanical `server_inference` translator under the legacy manifest producer; preserve one manifest lineage through execution/outcome; compare but do not apply projected debt. |
| 3 | Make NORMAL consume the projection and derive/prioritize debt; delete legacy slot-state-to-membership/grant interpretation atomically. |
| 4 | Refresh facts across attachment, cancellation, release, slot reuse and parent/child activation. Admission authority is unchanged. |
| 5 | Enforce activation commit -> mechanical outcome -> refreshed speculative/progress facts -> repriced debt -> target manifest. Delete both independent legacy activation decisions atomically. |
| 6 | Replace categorical cohort predicates with prompt/decode/replay debt predicates while retaining all six global phases and `E`/`X` hysteresis. |
| 7 | Add progress/debt telemetry and residue checks. Configuration and authority are unchanged. |
| 8 | Add projection, frontier, classification, manifest-continuity, cache/context/replay and authority-deletion regressions plus trace-consistent ROCm validation. |

The server/non-server split remains unchanged. Projection, debt derivation and controller policy are server-local. Common speculative, sampling, cache/checkpoint, model and backend mechanics remain unchanged.

## Required validation

CPU/fixture validation must cover:

- Ordinary and fully cached prompts, including forced last-token logits evaluation.
- Early prompt completion and exactly-once sampled debt.
- Fresh MTP/ngram preparation, full/partial acceptance and prepared-edge retraction.
- Checkpoint restoration and replay creation/consumption.
- Context shift: committed output progress remains monotonic while physical extent moves.
- `WAIT_OTHER` before parent copy and independent children after activation.
- Cancellation before/after preparation, release and slot reuse under a different task ID.
- Replay across cohort exit and multimodal intermission.
- MTP-OFF target-advanced survivors and LoRA MTP-OFF with ngram debt.
- One manifest lineage through preparation, retry views, target execution, post-decode and outcome.
- Absence of controller-owned copied prompt, sampled, replay, checkpoint, cache, speculative or frontier state.
- Absence of any legacy categorical scheduling interpretation after Phase 3.

Controlled validation is specifically required for:

- SWA/hybrid/recurrent checkpoint coverage because current source records inaccurate inferred checkpoint coverage for SWA at `tools/server/server-context.cpp:2791-2794`.
- Cache reuse plus forced last-token evaluation at `tools/server/server-context.cpp:4076-4091`.
- Context shift with monotonic accepted-output count and shrinking physical extent.
- Parent/child activation and runnable-stream recount.
- Fault-injected decode retry proving projections are published only at quiescent boundaries, never while prepared rows are uncommitted.

## Observability delta

Structured per-manifest diagnostics:

- Global controller phase and exact member/cohort identity.
- Reconciled prompt commitment and accepted-output count.
- Pending sampled debt, prepared/replay extent and derived debt set.
- Maximum reservation, actual row cost and authorization/hold reason.
- Outcome advancement, prepared retraction, replay creation/consumption, completion/cancellation/release.
- Projection refresh cause.
- Physical target/draft positions explicitly marked diagnostic and non-semantic.

Prometheus remains aggregate and low-cardinality: debt/rows by phase/class, reserved-versus-actual rows, held/blocked counts, committed advances, prepared retractions, refresh causes and manifest/outcome mismatch count. Task, slot, lease, cohort and manifest identities remain structured-log/debug-only.

## Deferred boundary

The new seam enables but does not absorb:

- Manifest-view-aware speculative processing.
- Paged target-KV work.
- Prompt-checkpoint DRAM-copy optimization.
- Dynamic mid-decode MTP reconstruction.

All remain in `deferred-todo-work.md`. The active refactor preserves the complete verification-prefix limitation and existing cache/speculative/model/backend mechanics.

## Proposed active-document rewrite boundary

If approved, revise `COHORT_BATCHING_CONTROLLER_DESIGN.md` in these areas:

1. Objective and authority/dependency boundaries.
2. Persistent-state exclusions and global-phase definition.
3. Facts/proposals and iteration-planning contract.
4. Speculative row accounting, target-row rules and prompt grants.
5. Stream counting, phase predicates and early completion.
6. Replay/checkpoints and speculative-profile wording.
7. Invariants, critical-path boundary, observability and tests.
8. Architecture review boundary.

Revise `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md` across Phases 0-8 according to the table above, without phase renumbering, authority redesign, workstream changes, or deferred-scope expansion.
