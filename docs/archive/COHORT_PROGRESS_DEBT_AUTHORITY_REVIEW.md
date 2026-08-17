# Cohort Progress/Debt Authority Review

Status: three fresh independent reviews completed. Conditional approval only. This review does not authorize implementation or edits to the active controller design and phased implementation plan.

Reviewed proposal: `COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md`.

## Verdict

The progress/debt direction is sound and requires no second persistent scheduling authority. The reviewed proposal is not ready to merge verbatim. Several boundaries must be corrected first.

The durable authority chain is:

```text
raw authoritative facts
    -> proposal
    -> inference::control commit
    -> mechanical mutation/execution
    -> tagged outcome
    -> refreshed facts at an explicit quiescent boundary
```

No adapter, executor, cache owner, speculative runtime, or batching component may fill an omitted policy decision.

## Blocking corrections

### 1. Reconciliation is authorized mutating preparation, not passive projection

The reconciled prompt prefix does not exist as a passive slot field. Local `n_past` is produced while STARTED processing mutates prompt/cache/checkpoint/speculative/memory state:

- `tools/server/server-context.cpp:3786-4125`
- Target-memory truncation at `tools/server/server-context.cpp:4138-4143`
- Immediate prompt-row preparation at `tools/server/server-context.cpp:4210-4235`

Required staged contract:

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

No target work, admission sweep, phase transition, fairness advancement, or unrelated scheduling decision occurs between these stages.

`server_inference` may translate passive facts. It must not perform or conceal reconciliation. An unreconciled member cannot satisfy the zero-prompt-debt cohort barrier.

### 2. One iteration lineage contains several controller commits

The first-pass phrase “one committed manifest” collapses necessary authorization stages. Exact rows and prompt grants are not all knowable before reconciliation and drafting.

Retain distinct commit types inside one immutable iteration lineage:

```text
iteration lineage
    committed activation action, when applicable
    committed decode-preparation action
    committed prompt-reconciliation/preparation action
    tagged preparation outcomes
    final committed target batch
    mechanical retry views
    complete execution outcome
```

Only the final committed target batch authorizes target execution. Execution may assign offsets mechanically for committed blocks/grants; it may not select membership, distribute residual capacity, or finalize policy.

The lineage requires an immutable handle/reference passed through preparation, retry, post-decode and outcome reporting. It need not be a new persistent controller lifecycle or process-global monotonic ID.

### 3. Control derives `R`; the adapter reports raw dependency/task facts

There is no source-owned “eligible independently runnable cohort stream” boolean. It combines mechanical and policy semantics, including task kind, dependency state, aLoRA, multimodal/exclusive work and policy-held members.

`server_inference` reports raw facts:

- Exact current `{slot_id, task_id}` and attachment/liveness.
- Existing lifecycle state as a mechanically interpreted source fact.
- Task kind and dependency identity/satisfaction.
- Adapter/aLoRA facts.
- Speculative runtime capability/synchronization facts.

`inference::control` applies the approved eligible-stream predicate and derives `R`. A mechanical fact may be named `dependency_satisfied`; it must not silently mean cohort eligibility.

Evidence:

- Slot liveness: `tools/server/server-context.cpp:560-562`
- WAIT_OTHER attachment: `tools/server/server-context.cpp:2239-2246`
- Parent-copy activation: `tools/server/server-context.cpp:4434-4453`
- Existing controller ownership: `COHORT_BATCHING_CONTROLLER_DESIGN.md:590-610`

### 4. Policy consumes outcomes only after the complete logical manifest closes

The server may process one logical batch through several `batch_view`s and invoke post-decode handling after each view at `tools/server/server-context.cpp:3460-3499`.

Per-view results may be accumulated mechanically. Control must not refresh global progress, advance a barrier, derive `R`, admit work, or plan the next iteration until:

- Every view of the committed logical manifest has executed and completed post-processing; or
- The manifest has reached one explicit terminal failure outcome.

This preserves the current whole-verification-prefix limitation. It does not introduce manifest-view-aware speculative processing.

The outcome snapshot retains exact manifest membership and `{slot_id, task_id}` before release can move/clear current-task state at `tools/server/server-context.cpp:678-705`.

### 5. Phase 3 must enumerate the exact legacy authority deletion

Current categorical scheduling authority spans:

- Generating selection and speculative preparation: `tools/server/server-context.cpp:3629-3745`
- Prompt membership, compatibility, reconciliation and grants: `tools/server/server-context.cpp:3754-4292`
- Context-shift maintenance selected from generating state: `tools/server/server-context.cpp:3546-3612`
- Independent MTP timing retained temporarily until Phase 5: `tools/server/server-context.cpp:3614-3618`, `4512-4518`

Phase 3 must explicitly catalogue:

- Scheduling uses of `SLOT_STATE_*` deleted at takeover.
- Mechanical lifecycle/response uses retained in `server_inference` and post-decode mechanics.
- Controller-authorized context-shift/reconciliation maintenance.
- The sole temporary exception: isolated legacy NORMAL MTP activation timing, removed atomically in Phase 5.

After Phase 3, no path outside the mechanical fact translator/outcome mechanics may derive target membership, grants, preparation, or maintenance authorization from categorical slot state.

### 6. Oversized verification-prefix failure still needs an authority decision

Mechanical retry may derive reduced prompt-tail views only while preserving committed membership and the complete verification prefix. Current retry construction and effective-capacity reduction occur at:

- `tools/server/server-context.cpp:3460-3494`
- `tools/server/server-context.cpp:4409-4416`

If the complete verification prefix cannot fit, execution must not independently drop a member, disable speculation, slice a block, or create replacement work.

The existing open decision must choose one authority path:

1. Control preauthorizes one exact failure/cleanup action as part of the committed work; execution applies it mechanically; or
2. Execution reports `verification_prefix_unfit`, existing runtime owners apply only explicitly committed restoration/abort work, and control commits a new plan.

This is a pre-existing active-plan blocker exposed again by the progress/debt review.

## Required contract corrections

### Lifecycle-gated progress names

Rename the semantic tuple to avoid implying a computed-token frontier:

```text
(reconciled_prompt_coverage, output_committed_count)
```

`output_committed_count` is lifecycle-gated `n_decoded`, not raw speculative acceptance. Replay material is not output-committed progress until replay succeeds and existing output processing advances `n_decoded`.

Current slot fields survive reset/reuse and require exact current-task lifecycle gates:

- `WAIT_OTHER`: no runnable progress/debt.
- `STARTED` or unreconciled prompt: output committed count is semantically zero; stale `n_decoded`, `sampled`, and `has_next_token` are ignored.
- Reconciled incomplete prompt: output committed count remains zero.
- `DONE_PROMPT` before sampling: zero output committed count.
- Exact live `GENERATING`: `n_decoded` is authoritative; pending sampled input is derived only at a legal quiescent/preparation seam.

Evidence: `tools/server/server-context.cpp:452-492`, `2251-2282`, `4279-4291`, `4530-4544`, `4667-4686`.

The tuple describes monotonic logical request progress. It never determines physical target position or proves that no target row is owed. Fully cached prompts may deliberately require last-token evaluation at `tools/server/server-context.cpp:4076-4081`.

### Debt, proposals, and authorization are separate

Use three terms consistently:

```text
pending work/debt
    phase-neutral derivation from owner facts

priced proposal
    batching-selected reservation/block/grant proposal

authorized work
    control-committed action or final target batch only
```

“No pending target debt” cannot mean “not authorized in this phase.” INTERMISSION and cohort barriers preserve visible debt while withholding authorization.

### Prepared verification is a tagged preparation outcome

Fresh drafting mutates speculative/runtime state. Its exact block identity and actual rows return as a preparation outcome bound to the already selected member and iteration lineage. They do not re-enter the general candidate-fact path and cannot cause reselection.

Retain an opaque descriptor equivalent to the existing `prepared_decode_block` contract:

```text
block identity
exact owner
fresh or replay origin
actual atomic target rows
```

Batching packs descriptors; it does not scan `spec_draft`, `spec_i_batch`, checkpoint or implementation internals.

### Replay row meaning is exact

On checkpoint replay, `spec_draft` contains retained accepted replay tokens and `spec_is_replay` owns the classification at `tools/server/server-context.cpp:4612-4631`.

The next target block contains:

```text
one sampled base row + retained replay tokens
```

If a fact reports retained tokens, call it `replay_token_count` and price `1 + replay_token_count`. If it reports total block rows, call it `replay_rows`. Never maintain either in control.

### Runtime speculative facts and cohort policy remain distinct

Do not overload one `speculative_eligible_mask`:

- Runtime/capability mask: existing speculative owner.
- Stateful synchronized mask: existing speculative owner.
- Immutable cohort allowed profile: `inference::control`.
- Effective reservation input: explicit result after committed activation/profile application.

An MTP-OFF cohort never regains MTP merely because runtime eligibility reports it.

### Phase 5 prompt-completion ordering is explicit

Generating-scan path:

```text
facts
    -> control activation commit
    -> mechanical attempt
    -> refreshed runtime masks/maxima
    -> debt pricing/reservation
```

Prompt-completion path:

```text
prompt target outcome
    -> control activation commit
    -> mechanical activation
    -> common_speculative_begin() exactly once
    -> sampling/client outcome
    -> quiescent progress refresh
    -> next iteration lineage
```

Debt never decides MTP eligibility or activation timing.

### Phase 4 wording is corrected

The progress/debt delta adds no new admission authority. Phase 4's existing accepted-set/window transfer to control remains unchanged.

Parent/child activation is an execution outcome after mechanical state copying, not admission. Refresh its facts only at complete-manifest closure.

### Phase 0 evidence remains honest

With “Source commit: none,” Phase 0 can capture source-annotated fixtures and currently observable manifests/outcomes only. Live shadow projection of transient reconciled facts begins with the Phase 2 translator unless Phase 0 explicitly authorizes behavior-neutral diagnostic instrumentation.

## Authority matrix after correction

| Concern | Authority |
| --- | --- |
| Raw slot/task lifecycle and current task state | Existing slot/task owner |
| Cache/checkpoint/speculative reconciliation mechanics | Existing owners under control-committed member scope |
| Reconciled-prompt outcome | Mechanical execution result, exact-member and lineage tagged |
| Raw fact translation | `server_inference`, passive and history-free |
| Eligible-stream predicate and `R` | `inference::control` |
| Pending debt derivation and row/grant pricing | `inference::batching`, proposal only |
| Activation, preparation, phase and final target authorization | `inference::control` |
| Draft/replay/checkpoint lifecycle | Existing speculative runtime and slot |
| Target execution and retry-view construction | `server_execution`, mechanical under the committed batch |
| Complete outcome publication | `server_execution`, lineage-tagged after all views settle |
| Next phase/admission/work decision | `inference::control` |

## Review result

Conditional approval after the first-pass findings are revised with the corrections above.

The following passed cleanly:

- No new persistent computed frontier is justified.
- Logical progress remains an ephemeral current-task tuple.
- Prepared/speculative extent and physical memory remain separate.
- Existing queue, slot/task, speculative, cache/checkpoint, adapter and MTP runtime owners remain authoritative.
- `inference::batching` remains stateless and proposal-only.
- The six global controller phases remain valid.
- The server/non-server split remains valid.
- No deferred project enters the active refactor.
