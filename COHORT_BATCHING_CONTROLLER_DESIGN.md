# Inference Control and Cohort Batching Design

Status: architecture contract for review. This document does not authorize implementation.

Source inspected: current working tree based on commit `91a5c4911c86fa9e8b85fda27be0e6abeb75b574`, including the pre-existing local speculative/server changes. Those user-owned changes were not modified by this architecture work.

## Objective

Replace the server's scattered inference-orchestration decisions with one durable controller. The controller must be the sole authority for inference admission and target-batch scheduling while leaving queue storage, slot state, speculative state, prompt/cache state, replay, and model execution with their existing owners.

The controller owns explicit global scheduling phases. It does not assign a second execution phase to each member. Per-member work is derived at decision boundaries from ephemeral current-task facts: reconciled prompt coverage, output committed by existing response processing, pending sampled input, prepared verification/replay, and orthogonal eligibility/capability facts. Prepared speculative extent may retract, and physical KV/cache positions may move independently; neither is monotonic logical request progress. The controller stores no persistent computed frontier. Logical progress is the lifecycle-gated (reconciled_prompt_coverage, output_committed_count) tuple. Prepared/speculative extent, pending target debt, and physical execution state are four distinct domains that remain authoritative in their existing owners outside the global scheduling phase.

The first scheduling policy added to that controller is threshold-triggered cohort batching:

1. Below the configured entry stream threshold, preserve normal generation-first continuous batching.
2. When control-derived `R` reaches that threshold with no lifecycle/task blocker, ask `inference::admission` to assess the complete exact formation scope; control commits or rejects that assessment without recalculating it.
3. If any attached stream still has decode-family work, close ordinary inference admission and drain every such decoder while holding all prompt-family work. Threshold crossing creates only this entry intent, not a cohort.
4. At that decode boundary, give one ready multimodal task an exclusive intermission before any concurrent prompt cohort begins.
5. Form and freeze the next admitted prompt cohort.
6. Prefill that cohort concurrently using contiguous, fairly distributed prompt grants.
7. Hold members that finish prefill early at the barrier after sampling their first token.
8. Decode the cohort together while its live stream count remains above the configured exit stream threshold.
9. When the live count reaches the lower exit threshold, end that cohort lifecycle and return to the boundary decision before the next target batch.

Each cohort freezes one homogeneous speculative profile at formation. MTP is either immediate for every member for the complete cohort lifecycle or OFF for every member. An MTP-OFF cohort performs target-only prefill with no NextN hidden-state capture, DRAM archive allocation/copy, deferred backfill, activation scan, or MTP verification row. LoRA-active cohorts require MTP-OFF until adapter-equivalent target/draft behavior is separately proven. Ngram remains independently eligible. NORMAL retains its existing dynamic/deferred MTP policy as a separate authority-migration concern.

## Existing authority map

There is currently no standalone scheduling controller. `server_context_impl` is the aggregate owner, but orchestration authority is distributed across the following paths.

```text
HTTP task creation
        |
        v
server_queue
pending / deferred / reinsertion
        |
        v
process_single_task
slot selection + admission + speculative occupancy
        |
        v
pre_decode
context shift + MTP activation + drafting
+ sampled/verification rows + prompt rows
        |
        v
server_batch / llama_decode
        |
        v
common_speculative_process
        |
        v
post_decode
sampling + verification + replay + release
        |
        v
release callback immediately promotes deferred work
```

Relevant current locations (exact legacy authority and Phase 3/5 dispositions below):

- HTTP completion task construction: `tools/server/server-context.cpp:4857-4907`.
- Monotonic queue task IDs: `tools/server/server-queue.cpp:71-75`.
- Queue drain before inference: `tools/server/server-queue.cpp:139-168`.
- Deferred insertion and reinsertion: `tools/server/server-queue.cpp:63-100`.
- Slot selection: `tools/server/server-context.cpp:1908-2068`.
- Inference admission, speculative occupancy, cache restore, and MTP mode selection: `tools/server/server-context.cpp:2817-3052`.
- Immediate deferred-task promotion from slot release: `tools/server/server-context.cpp:1656-1668`.
- Inference iteration: `tools/server/server-context.cpp:3392-3500`.
- Current batch scheduling and construction: `tools/server/server-context.cpp:3543-4331`. Phase 3 deletes the exact legacy catalogue: generating selection/speculative preparation (3629-3745), prompt membership/compatibility/reconciliation/grants (3754-4292), and context-shift maintenance (3546-3612); the pre_decode MTP activation pass (3614-3618) and the post_decode prompt-completion activation (4512-4518) remain the two temporary MTP exceptions until Phase 5 removes both.
- Target and speculative execution: `tools/server/server-context.cpp:4335-4455`.
- Sampling, verification, rollback, replay, and release: `tools/server/server-context.cpp:4460-4701`.

Controlling only `pre_decode()` is insufficient. Slot release currently promotes deferred tasks before the next batch plan, and speculative occupancy is decided during admission. Both paths can change the admitted workload underneath a frozen cohort.

## Authority boundary

One controller does not imply one monolithic scheduling subsystem. Scheduling is decomposed into fact producers, proposal calculators, one policy committer, and mechanical applicators.

The authority chain is always:

```text
authoritative state
    -> passive raw facts
    -> admission/batching proposal
    -> inference::control commit
    -> server mechanical application
    -> exact-stream, iteration-tagged outcome
    -> refreshed facts at an explicit quiescent boundary
```

Only `inference::control` commits scheduling policy. A proposal has no effect until control accepts it.

`inference::control` exclusively commits:

- Whether inference admission is open.
- Which proposed candidate set becomes an admission transaction.
- When cohort mode begins and ends.
- The current global phase and exact active-cohort membership.
- Which proposed NORMAL compatibility group, decode blocks, prompt grants, or external operation may run.
- Which exact streams enter the committed prompt-reconciliation membership; reconciliation runs as a staged exact-stream stage (batching proposes members, control commits, owners reconcile mechanically, tagged outcomes publish, one global snapshot follows) before any grant.
- One iteration lineage may contain several committed preparation actions; only the final target-batch commit authorizes target execution.
- When NORMAL deferred MTP activation/backfill may be attempted; cohort phases never attempt it.
- When deferred tasks may be promoted into released slots.

No proposal component or downstream adapter may independently advance phase, mutate membership, admit inference, or add model work outside a control commit.

`inference::control` does not own:

- Queue contents or ordering.
- Task objects.
- Slot state.
- Prompt tokens or cache state.
- Draft tokens or speculative state.
- MTP archives.
- Checkpoints or replay state.
- `server_batch` storage.
- Model contexts or execution.
- Sampling or response delivery.
- Per-member progress, pending debt, prepared-block, reconciliation-result, or physical-position mirrors.

## Namespace and dependency boundary

The monolithic `namespace inference_scheduler` design is retired. The mechanism is divided by authority:

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
    struct adapter_binding {
        uint64_t adapter_id;
        float scale;
    };
    struct adapter_signature {
        std::vector<adapter_binding> ordered;
    };
    enum class cohort_mtp_mode { OFF, IMMEDIATE };
    struct cohort_speculative_profile {
        cohort_mtp_mode mtp;
        uint32_t non_mtp_eligible_mask;
    };
}

namespace inference::control {
    enum class phase;
    struct active_cohort;
    struct control_state;
    struct admission_commit;
    struct mtp_activation_commit;
    struct decode_preparation_commit;
    struct prompt_reconciliation_commit;
    struct target_batch_commit;
    struct external_target_commit;
    struct model_mutation_commit;
    struct iteration_completion;
    class controller;
}

namespace inference::admission {
    struct admission_candidate;
    struct admission_proposal;
    struct formation_assessment;
}

namespace inference::batching {
    struct pending_work;
    struct draft_reservation;
    struct mtp_activation_proposal;
    struct decode_preparation_proposal;
    struct prompt_reconciliation_proposal;
    struct target_batch_proposal;
}

namespace server_inference {
    struct stream_snapshot;
    struct placement_plan;
    class snapshot_reader;
    class admission_adapter;
}

namespace server_execution {
    struct prompt_reconciliation_outcome;
    struct prepared_decode_outcome;
    struct target_batch_outcome;
    struct model_mutation_outcome;
    class executor;
}
```

The catalogue above is the end-state namespace map, not the Phase 1 source surface. Phase 1 materializes only identity/profile values; `phase`, `config`, and `active_cohort` values; passive raw snapshot plus lifecycle projection DTOs; the producer-owned exact-stream `prompt_reconciliation_result` whose local meaning is already known; and leaf-pure formation, NORMAL compatibility, decode-reservation, and prompt-row-grant proposals. It contains no commands, executor/adapter interface, pending-work or reconciliation selection, prepared/target outcomes, manifest, or execution lineage. Those contracts begin in the later owning phases at the real server seams.

`inference::identity` and `inference::profile` are value-only vocabularies under `tools/server`; they contain no behavior or mutable state and do not imply extraction into `common`. Do not introduce generic buckets such as `inference::types`, `inference::facts`, `inference::utils`, or `inference::scheduler`.

Component authorities are:

| Component | Owns | Does not own |
| --- | --- | --- |
| `inference::identity` | Strong scheduling identity value types shared by the server-local components | Policy, lookup, lifecycle or mutable state |
| `inference::profile` | Immutable adapter/speculative policy value types | Runtime masks, draft contexts, archives or activation mechanics |
| `inference::control` | Global phase machine, monotonic cohort/iteration identities, exact membership, immutable cohort adapter/speculative profiles, stream classification and `R`, exact multimodal intermission grant, barriers, sequencing, committed prompt cursor, explicitly named preparation commands and sole final target authorization | Queue storage, placement mechanics, per-stream progress/debt, media/helper progress, batch construction, speculative state |
| `inference::admission` | Accepted-set proposal plus the sole calculation of whole-set formation compatibility, exact adapter signature and homogeneous speculative profile for the control-selected scope | Input fact ownership, blocker/phase policy, queue order, slot mutation, admission commit |
| `inference::batching` | Pure pending-work derivation, NORMAL compatibility grouping and MTP activation-set proposals from speculative eligibility facts; worst-case pricing; atomic-block packing; contiguous prompt grants and next prompt-cursor proposals | Phase advancement, `R`, authorization, membership mutation, adapter switching, speculative runtime mutation, execution |
| Existing `server_queue` type | Ready/deferred/leased task storage, exact order, cancellation visibility and queue-owned admission leases | Cohort policy and slot placement |
| `server_inference::snapshot_reader` | Passive history-free snapshots and lifecycle-gated passive progress projection | Placement, attachment, preparation, compatibility policy, `R` and work selection |
| `server_inference::admission_adapter` | One queue-lease-bound placement/attachment transaction: create the exact placement plan, retain its transaction-local reservations, and apply that same committed plan once | Queue order, accepted-set policy, cohort compatibility, cache/speculative initialization |
| `server_execution::executor` | Typed mechanical execution of every control command, including cache/speculative initialization, reconciliation/preparation, target/external work, model mutation, retry views and exact outcomes | Stream/group/grant discovery, residual-capacity allocation, adapter switching policy and phase policy |
| Existing speculative policy | Speculative implementation eligibility and occupancy calculation | Scheduling phase and activation timing |
| Existing speculative runtime | Draft, capture, backfill, verification, acceptance, rollback and replay mechanics | Admission and batch scheduling policy |

Compile-time dependency and runtime data flow are distinct.

The compile-time direction is one-way:

```text
inference::identity / inference::profile
    -> passive snapshot and producer-owned result DTO headers
    -> inference::admission / inference::batching / inference::control contracts
    -> server adapter and executor implementations
    -> server_context mechanical driver
```

Snapshot/result DTO declarations remain separate from the adapters that consume control commits. Control may include those DTO contracts; snapshot/result headers never include the controller or executor. Results are owned by their mechanical producers rather than classified as passive snapshots. This prevents `inference::control` and `server_execution` from including each other.

The runtime flow is:

```text
passive snapshot
    -> admission/batching proposal
    -> inference::control exact commit
    -> server mechanical application
    -> complete tagged outcome
    -> refreshed passive snapshot
```

Namespaces express authority, not automatic source placement. Server-shaped integrations remain under `tools/server`. A policy component moves to `common` only when its public facts and proposals are genuinely host-neutral. Removing server includes or renaming server concepts is not sufficient evidence of neutrality.

No `inference_scheduler` umbrella namespace or catch-all source pair is introduced.

## Persistent state

```cpp
namespace inference::control {
struct active_cohort {
    inference::identity::cohort_id id;

    // Empty means base/no-LoRA. Otherwise this exact ordered adapter set and
    // exact scales are immutable throughout the active cohort.
    inference::profile::adapter_signature adapters;

    // Scheduling policy only. Speculative contexts, masks, drafts and archives
    // remain owned by the existing speculative policy/runtime and slots.
    inference::profile::cohort_speculative_profile speculation;

    // Exact identity prevents slot reuse from inheriting membership from the
    // slot's previous task.
    std::vector<inference::identity::stream_key> members;

    // Control owns the committed cursor. inference::batching proposes its next
    // value when proposing contiguous prompt grants.
    size_t prompt_cursor;
};

struct control_state {
    phase current_phase;
    uint64_t next_cohort_id;
    uint64_t next_iteration_id;
    std::optional<active_cohort> cohort;
    std::optional<inference::identity::stream_key> intermission_task;
};

class controller {
    control_state state;
};

} // namespace inference::control
```

`inference::admission` and `inference::batching` do not own mutable scheduling state. They calculate proposals from facts plus the last committed control state. Heterogeneous adapter lanes are not part of cohort policy, so no cohort lane cursor or lane-fairness state exists. Only `active_cohort::prompt_cursor` is required inside the homogeneous cohort.

`active_cohort::members` remains in initial mechanical attachment order. Pruning uses stable erase and never reorders survivors. `prompt_cursor` is an index into that ordered live vector, normalized after every stable erase: removal before the cursor decrements it; removal at the cursor leaves the index naming the immediate surviving successor; an empty vector resets it to zero. When grants exist, control commits the successor of the first member actually granted, so the batch starting member rotates even when every member receives a grant. With no grant it retains the normalized supplied cursor. Reconciliation, preparation, retry and execution outcomes never advance it. It is prompt fairness state only and is never reused to choose speculative/decode participation.

`control_state` gains no per-member lifecycle stage, prompt/output frontier, pending-work set, reconciliation flag, sampled token, prepared block, replay flag, cache position, or speculative-runtime mirror. Those values remain authoritative in their existing owners and are projected only for the current decision. Control stores no new persistent computed frontier of any kind. The iteration lineage needs only an immutable handle passed through preparation, retry views, post-decode and outcome reporting; it is not a new persistent controller lifecycle or process-global ID. `next_iteration_id` allocates a monotonically increasing correlation identity; an iteration itself remains a transient scheduling/execution transaction rather than another persistent controller lifecycle.

`intermission_task` stores only the exact task identity selected by control for the current one-task multimodal boundary grant. Queue ownership, slot/task lifecycle, media position, encoded batches and helper progress remain with their existing owners. Control sets the pair when mechanical attachment succeeds and clears it only while atomically leaving INTERMISSION after completion/cancellation; this prevents slot reuse or another queued multimodal task from inheriting the grant.

`inference::profile::adapter_signature` is value equality over the exact ordered adapter set and exact scales; it is not a hash-only identity. The empty signature represents base/no-LoRA. `server_inference::snapshot_reader` mechanically emits the canonical existing adapter order and scales; `inference::admission` alone calculates whole-set signature/profile compatibility, and control alone commits or rejects that assessment.

`inference::profile::cohort_speculative_profile` is immutable scheduling policy. Its non-MTP mask and MTP-OFF/MTP-IMMEDIATE value do not mirror runtime implementation state.

Configuration is not mutable scheduling state:

```cpp
namespace inference::control {
struct config {
    int32_t entry_streams;
    int32_t exit_streams; // 0 < exit_streams < entry_streams
};
}
```

The shared argument layer carries only plain optional entry/exit values. The server adapter constructs `std::optional<inference::control::config>`; absence means disabled. No `inference::*` policy type is added to `common`.

`next_cohort_id` is monotonic for the serving process. Cohort formation allocates one ID and atomically binds it to the immutable adapter and speculative profiles, exact initial `{slot_id, task_id}` membership, and initial prompt cursor. The ID remains stable while that cohort lifecycle is active, including membership pruning and PREFILL-to-DECODE transitions. When the eligible stream count reaches the configured exit threshold, the lifecycle ends and `control_state::cohort` is cleared rather than mutating or reusing its ID.

Before that commit, `COHORT_ENTRY_DRAIN` incumbents come from exact attached-slot facts under a controller-closed admission window, and the closing FORM proposal carries its accepted signature and pair set transaction-locally. They are not assigned a provisional cohort ID and do not require a second persistent membership catalogue.

The identity domains remain distinct and are not interchangeable integer conventions:

- `task_id` identifies one task/request lifecycle.
- `slot_id` identifies the current physical execution container.
- `inference::identity::stream_key { slot_id, task_id }` identifies an exact stream and prevents slot-reuse inheritance.
- `cohort_id` identifies the stable scheduling-group lifecycle.
- `iteration_id` identifies one complete scheduling/execution transaction from snapshot through complete outcome.
- `lease_id` belongs to a queue admission transaction. A lease may abort or exist outside cohort formation and is never a cohort identity.

`max(task_id)` is not a cohort identifier or sufficient diagnostic identity: cancellations change the live maximum, deferred tasks may be older than current work, and synthetic tasks consume task IDs. `cohort_id` is emitted in structured logs and debug APIs, not as a Prometheus label.

## Phases

```cpp
namespace inference::control {

enum class phase {
    NORMAL,
    COHORT_ENTRY_DRAIN,
    COHORT_INTERMISSION,
    COHORT_FORM,
    COHORT_PREFILL,
    COHORT_DECODE,
};

} // namespace inference::control
```

`NORMAL` is controller-owned. There must not be a legacy scheduler operating underneath it.

These phases express global authorization policy, not a summary of member execution state. Existing `SLOT_STATE_*` values remain mechanical slot/task lifecycle facts needed to reject stale reused-slot fields and translate current-owner state. After target-work takeover they cannot independently select scheduling membership, grants, preparation, or maintenance outside the mechanical translator and outcome paths.

## Facts and proposals

The server adapters materialize ephemeral fact vectors from authoritative state and pass the aggregate by `const &`. The project targets C++17, so the contract does not require `std::span`. Owning ephemeral vectors are not persistent mirrored state.

Passive raw facts contain exact identity, attachment/liveness, current mechanical lifecycle, exact source operation identity, input kind, dependency identity/satisfaction, adapter/aLoRA facts, and speculative/cache capability facts. Source operations such as COMPLETION and INFILL remain distinct even when both consume token-sequence input; multimodal is an input kind, not a fabricated task operation. These facts do not contain an adapter-computed `independently_runnable` or cohort-eligibility boolean. `inference::control` applies the approved eligible-stream predicate to raw facts and derives `R`.

The source has no safe singular stored computed-token frontier. For one exact current task, logical progress is projected as:

```text
(reconciled_prompt_coverage, output_committed_count)
```

`reconciled_prompt_coverage` is a tagged outcome of authorized mutating prompt reconciliation, not a passive read of `slot.prompt.tokens`, `n_prompt_tokens_processed`, or physical KV positions. `output_committed_count` is lifecycle-gated `n_decoded`; it is semantically zero for WAIT_OTHER, STARTED, unreconciled/incomplete prompt, and DONE_PROMPT-before-sampling states, whose raw slot fields may be stale after reuse. A pending sampled input is already included in output-committed progress but still owes one target evaluation.

Pending work is a phase-neutral derived set, not another stored or mutually exclusive stage enum:

```text
prompt/reconciliation work
sampled-token work
fresh speculative verification work
mandatory replay work
```

Keep three terms distinct: pending work is derived from owner facts; a priced proposal is calculated by `inference::batching`; authorized work exists only after an `inference::control` commit. A barrier or INTERMISSION may hold visible pending work without making it disappear.

```cpp
// Nested value types on the existing global server_queue struct; server_queue
// is not also introduced as a namespace.
struct server_queue {
    struct lease_id { uint64_t value; };
    struct leased_candidate {
        int64_t task_id;
        uint32_t queue_ordinal;
    };
    struct admission_lease;
};

namespace server_inference {
struct reserved_placement {
    int64_t task_id;
    int32_t slot_id;
};

struct placement_plan {
    server_queue::lease_id lease;
    std::vector<reserved_placement> exact;
};

struct stream_snapshot {
    inference::identity::stream_key stream;
    // Passive current-task lifecycle, task-kind, dependency, adapter/aLoRA,
    // liveness, runtime capability and progress-source facts only.
};
}

namespace inference::admission {
struct admission_candidate {
    server_queue::leased_candidate queue;
    server_inference::reserved_placement placement;
    // Mechanical capability/profile facts, not a preselected cohort class.
};

enum class formation_incompatibility {
    NONE,
    MIXED_ADAPTER_SIGNATURES,
    NO_HOMOGENEOUS_SPECULATIVE_PROFILE,
};

struct formation_assessment {
    std::vector<inference::identity::stream_key> exact_scope;
    bool compatible;
    inference::profile::adapter_signature adapters;
    inference::profile::cohort_speculative_profile speculation;
    formation_incompatibility reason;
};

struct admission_proposal {
    server_queue::lease_id lease;
    server_inference::placement_plan placement;
    std::vector<int64_t> accepted_task_ids;
    std::optional<formation_assessment> formation;
};
}

namespace server_execution {
struct prompt_reconciliation_outcome {
    // Lineage tag: iteration binds the outcome to the multi-commit iteration lineage;
    // owner binds it to the exact member. Never a candidate-discovery fact.
    inference::identity::iteration_id iteration;
    inference::identity::stream_key owner;
    uint64_t prompt_total;
    uint64_t reconciled_prompt_coverage;
    int32_t contiguous_cap;
};

enum class decode_block_origin { FRESH, REPLAY };
struct prepared_decode_outcome {
    // Opaque descriptor: block identity, exact owner, fresh/replay origin, actual atomic
    // target rows. Lineage-tagged; never re-enters candidate discovery or reselection.
    inference::identity::iteration_id iteration;
    uint64_t block_id;
    inference::identity::stream_key owner;
    int32_t logical_rows;
    decode_block_origin origin;
};

struct target_batch_outcome {
    inference::identity::iteration_id iteration;
    // Complete exact-stream advancement, replay, completion, cancellation and
    // failure results captured before release/reset erases task identity.
};
}

namespace inference::batching {
struct pending_work {
    inference::identity::stream_key owner;
    // Exactly one typed prompt-reconciliation, sampled-token,
    // fresh-verification-candidate, or mandatory-replay work item, or none.
};

struct draft_reservation {
    inference::identity::stream_key owner;
    int32_t verification_rows_max;
};

struct mtp_activation_proposal {
    std::vector<inference::identity::stream_key> members;
};

struct decode_preparation_proposal {
    std::vector<draft_reservation> fresh;
};

struct prompt_reconciliation_proposal {
    std::vector<inference::identity::stream_key> members;
};

struct target_batch_proposal {
    std::vector<uint64_t> decode_block_ids;
    std::vector<std::pair<inference::identity::stream_key, int32_t>> prompt_grants;
    size_t proposed_next_cursor;
};
}
```

These names define semantic boundaries, not required storage layout. Passive facts belong to `server_inference`; completed mutating work belongs to `server_execution`; admission/batching own only calculations; and only `inference::control` creates commits. Control defines the exact formation scope and lifecycle/task-kind blockers, but it never recalculates signature or speculative-profile compatibility returned by `formation_assessment`. Exact fresh prepared outcomes cannot re-enter candidate discovery or permit reselection. Replay remains reported directly from existing `spec_is_replay`/`spec_draft` ownership: if the fact reports retained replay tokens, name it `replay_token_count` and price one sampled base row plus `replay_token_count`; if total block rows are reported, the field is named `replay_rows`.

The command matrix is normative:

| Proposal/input | Control command | Mechanical consumer | Result |
| --- | --- | --- | --- |
| `admission_proposal` | `admission_commit` | `server_inference::admission_adapter::apply()` | Attachment/cancellation result followed by refreshed `stream_snapshot` values |
| `mtp_activation_proposal` | `mtp_activation_commit` | `server_execution::executor` | Refreshed runtime masks/synchronization/maxima |
| `decode_preparation_proposal` | `decode_preparation_commit` | `server_execution::executor` | Exact `prepared_decode_outcome` values |
| `prompt_reconciliation_proposal` | `prompt_reconciliation_commit` | `server_execution::executor` | Exact `prompt_reconciliation_outcome` values |
| `target_batch_proposal` | `target_batch_commit` | `server_execution::executor` | One complete `target_batch_outcome` |
| Exact intermission target decision | `external_target_commit` | `server_execution::executor` | One exact task-scoped complete outcome |
| Boundary-eligible global model mutation | `model_mutation_commit` | `server_execution::executor` | One `model_mutation_outcome` followed by a refreshed passive snapshot |

No executor accepts a proposal directly. No adapter or executor manufactures, broadens, or substitutes a command.

Semantic fact production is also single-owner:

| Semantic value | Sole producer |
| --- | --- |
| Exact liveness, lifecycle, task kind, dependency, adapter/aLoRA and capability facts | `server_inference::snapshot_reader` |
| Lifecycle-gated `output_committed_count` and pending sampled-input fact | `server_inference::snapshot_reader` |
| `reconciled_prompt_coverage` and contiguous prompt cap | `server_execution::prompt_reconciliation_outcome` |
| Actual fresh/replay verification rows | `server_execution::prepared_decode_outcome` or the existing replay owner, respectively |
| Target advancement, completion, cancellation and replay creation | `server_execution::target_batch_outcome` |
| Pending-work derivation and row pricing | `inference::batching` |
| Lifecycle/task-kind blocker set, exact formation scope, `R`, phase and authorization | `inference::control` |
| Adapter/speculative compatibility of that exact formation scope | `inference::admission::formation_assessment` |

The post-reconciliation passive snapshot refreshes liveness and raw runtime state; it does not independently recalculate reconciliation coverage already reported by the tagged preparation outcome.

Runtime speculative eligibility, runtime synchronized state, the control-owned immutable cohort allowed profile, and the post-activation effective reservation input are distinct facts. An MTP-OFF cohort cannot regain MTP because runtime eligibility later reports it.

Operation classes are explicit:

- Cancellation, metrics, health queries and shutdown signalling remain immediately serviceable and are never blocked by inference-admission closure.
- Global model-state mutations, including `/lora-adapters`, remain queue-visible but control authorizes their application only at a cohort boundary through an exact `model_mutation_commit`.
- Slot/cache mutation operations require an individually documented classification before implementation; they are not covered by a generic control-task bypass.
- Ordinary inference tasks follow the admission-window policy in this document.

Every activation/preparation command, `target_batch_commit`, `batch_view`, mandatory post action, and `target_batch_outcome` after `active_cohort` creation carries its monotonic `iteration_id`, `cohort_id`, and exact `stream_key` values. NORMAL, `COHORT_ENTRY_DRAIN`, INTERMISSION, and pre-bind FORM actions carry no cohort ID but retain the iteration and stream identities. Cohort ID correlates one scheduling-group lifecycle; iteration ID correlates one snapshot-to-outcome transaction; neither replaces exact stream identity or becomes a slot/speculative-state lookup key.

## Admission contract

Admission becomes a cancellation-aware transaction rather than a series of unrelated per-task decisions.

An admission transaction proceeds as follows:

1. The existing `server_queue` creates one `server_queue::admission_lease` over a bounded candidate set while retaining ownership, exact order, and cancellation visibility.
2. `server_inference::admission_adapter::plan()` produces one transaction-local `placement_plan` that binds the lease ID to exact task-to-slot reservations in queue order without attaching tasks. The adapter retains those reservations; no later step reruns slot selection.
3. Existing speculative/cache owners report mechanical capability, synchronization and restore-mode facts for the complete placed set without taking cache entries or mutating slot, cache, or speculative state. They do not emit a formation-compatible verdict; `inference::admission` consumes the raw facts to calculate that verdict and choose homogeneous MTP-IMMEDIATE versus MTP-OFF.
4. For FORM, control supplies the exact complete formation scope after applying lifecycle/task-kind blockers. `inference::admission` calculates one `formation_assessment` for that scope and does not search for or select a smaller compatible subset. It then returns one `admission_proposal` containing the lease ID, exact placement plan, accepted task IDs and assessment.
5. `inference::control` emits an `admission_commit` binding that exact lease, accepted set, placement plan and compatible assessment, or rejects the proposal. Control does not rerun adapter/signature/speculative-profile compatibility. The committed assessment constrains the subsequent cohort decision but performs no runtime mutation by itself.
6. `server_inference::admission_adapter::apply()` consumes that exact committed placement plan once, performing minimal mechanical attachment in queue order. This is the queue-to-slot ownership cutover; it does not restore cache or mutate speculative runtime state.
7. `server_inference::snapshot_reader` reports the resulting exact `stream_key` values and any attachment/cancellation outcome.
8. For a closing FORM transaction whose classified `R` remains above the configured exit threshold, with no control-owned blockers and a compatible assessment for the unchanged exact scope, control allocates `next_cohort_id++` and atomically freezes the new ID, exact membership, the assessment's adapter/speculative profiles, and initial prompt cursor as one `active_cohort`. At or below the exit threshold, it allocates no ID and instead commits NORMAL initialization for the attached survivors.
9. Control emits the exact initialization command. `server_execution::executor` mechanically applies cache restore and speculative-profile initialization. A formed cohort receives MTP-IMMEDIATE for every live member or MTP removal plus target-only prefill for every live member; an unformed transaction receives NORMAL policy. FORM never assigns deferred MTP to a cohort.
10. The existing `server_queue` resolves the lease, restoring unaccepted candidates in exact relative order.

The task-ownership cutover is mechanical attachment of the exact `stream_key`. Until that point, the queue lease remains cancellation-visible; a cancellation invalidates the leased/staged candidate even after control accepted it. After attachment, cancellation is slot-owned. Before FORM cohort binding or INTERMISSION binding, `server_inference::snapshot_reader` reports any attached-then-cancelled stream as released and control excludes it. After a bind, cancellation is reconciled from the passive snapshot before another target authorization. A host-local swapped vector is not an admission boundary.

There is no target-model work between FORM attachment, the atomic `active_cohort` decision, and completion of committed profile/cache initialization. If initialization fails for a member, the existing admission-failure path releases that exact pair and control recounts before authorizing target work; it never silently changes the profile of a surviving live member. Ordinary NORMAL admission transactions do not allocate cohort IDs. An aborted lease does not become a cohort, and `lease_id` is never reused as `cohort_id`.

Existing cache-affinity, prompt-similarity, requested-slot and LRU placement remain mechanical allocator policies. Their output is the one transaction-local exact placement plan consumed by admission; several staged groups cannot select the same idle slot, and neither admission nor control recomputes placement.

The one `formation_assessment` across the complete exact FORM scope prevents early streams from receiving provisional adapter, MTP or cache-restore decisions that no longer match the final homogeneous cohort.

For cohort formation, the committed adapter signature and speculative capabilities determine one homogeneous profile:

- LoRA-active cohorts are MTP-OFF. Members receive no MTP mask; any pre-existing deferred archive/mode is cleared during committed post-attachment initialization; and members enter no immediate, capture, archive, backfill, activation, or MTP verification path.
- A base/no-LoRA cohort may be MTP-IMMEDIATE only when every member can enter and retain immediate MTP from formation through decode. Otherwise the complete cohort is MTP-OFF.
- Deferred MTP is never a cohort profile.
- Ngram remains independently eligible, but its permitted implementation mask/settings are also homogeneous profile policy rather than per-member scheduling authority.
- Any incumbent MTP lifecycle incompatible with the selected profile reaches the existing safe idle/demotion boundary before control may freeze the cohort. Active MTP state is never silently carried into an MTP-OFF cohort.

NORMAL admission continues to use the existing dynamic/occupancy-based immediate, deferred, and target-only policy. That behavior is not inferred from or changed by the cohort profile contract.

Admission stores no progress/debt projection at admission time. Per-member committed progress, pending target debt, prepared/speculative extent and physical execution state are rebuilt from authoritative owner facts at each decision boundary and discarded afterwards.

## Slot release contract

A slot release performs its existing slot/spec/archive cleanup and reports freed capacity. It does not autonomously promote another inference task.

```text
slot.release()
    -> clean slot/spec/archive state
    -> retain parent/child lifecycle cleanup
    -> do not promote inference directly
    -> next server_inference snapshot omits the released exact stream
    -> inference::control reconciles membership and commits any admission window
    -> server_queue leases candidates only after that commit
```

The queue continues to own candidate order. `inference::control` commits whether an inference admission window exists. Immediately serviceable operations and boundary-gated model mutations use the same queue-owned ordering domain and their explicit operation classifications; neither creates a second deferred queue.

When a released or cancelled `stream_key` belongs to an `active_cohort`, control removes it without changing `active_cohort::id`. A later task reusing the same slot can only belong to a later cohort with a new stream key and cohort ID.

## Canonical scheduling vocabulary

These terms are normative; implementation text should not use “logical batch,” “manifest,” and “iteration” interchangeably:

| Term | Exact meaning |
| --- | --- |
| `iteration_id` | Monotonic per-process identity for one snapshot-to-complete-outcome scheduling/execution transaction |
| `(reconciled_prompt_coverage, output_committed_count)` | Lifecycle-gated committed logical progress; `output_committed_count` is gated `n_decoded`; `reconciled_prompt_coverage` exists only as a tagged reconciliation outcome |
| Pending debt | Phase-neutral work derived from authoritative owner facts; visible work is not necessarily authorized |
| Priced proposal | `inference::batching`-calculated reservation/block/grant proposal with no authority |
| Authorized work | Control-committed action or final target batch only |
| Proposal | Pure admission/batching calculation with no side effect or authority |
| Commit | Exact command created only by `inference::control` |
| `target_manifest` | Exact logical target rows, owners, offsets, output requirements and verification-prefix layout |
| `target_batch_commit` | Sole authorization to execute one `target_manifest` |
| `server_batch` | Server storage encoding of the committed target manifest |
| `batch_view` | Retry/post-processing view over that `server_batch`; it is not a new scheduling decision |
| `n_batch` | Logical target-row capacity used for scheduling and reservation |
| `n_ubatch` | Backend physical microbatch capacity, invisible to scheduling policy |
| `target_batch_outcome` | One complete result published only after every view and mandatory post action settles |
| `iteration_completion` | Control-consumed proof that every command and required outcome for one `iteration_id` settled; it may contain a target, external, model-mutation, admission-only, zero-work, or terminal-failure result |
| Cohort | Multi-iteration scheduling lifecycle identified by `cohort_id` |

The final target commit authorizes its complete mandatory completion protocol: target decode, sampling, speculative processing, acceptance/rollback/replay creation, parent/child mechanical copying, response outcome capture and release/reset. These consequences do not require a second `committed_post_actions` policy command.

## Mechanical dispatch point

`server_context::update_slots()` remains the event-loop driver and becomes the single mechanical dispatch point:

```text
collect passive server_inference snapshot
    -> inference::control::next_action(...)
    -> dispatch the returned exact commit to server_inference or server_execution
    -> collect exact command outcomes
    -> finish mandatory mechanical post actions
    -> submit one iteration_completion
    -> refresh the passive snapshot
```

The driver may pump this sequence more than once in one scheduling turn, but it cannot select members, classify compatibility, advance phase, allocate rows, discover extra work, or substitute a different command. `inference::control` is the sole policy authority; `update_slots()` is the pump, not a second orchestrator. The driver assembles `iteration_completion` only after every `batch_view` and mandatory post action settles — complete-manifest closure is the sole bridge from execution outcomes to refreshed policy facts.

## Iteration-planning contract

Speculative verification size and exact legal prompt spans are not both known before preparation. One monotonic `iteration_id` therefore correlates several explicit proposal/commit/outcome stages; it is not one prematurely committed target manifest:

1. The previous iteration reaches a quiescent boundary: every issued command, `batch_view`, mandatory post action, response capture and release/reset has completed, or the iteration has one terminal failure outcome. The mechanical driver submits one `iteration_completion`; only then may policy consume results.
2. `server_inference::snapshot_reader` publishes passive exact-stream lifecycle, task-kind, dependency, adapter/aLoRA and capability facts. Control allocates the next monotonic `iteration_id`, classifies runnable/capable/blocking streams, derives `R`, reconciles cohort membership, and commits any phase/admission boundary before preparation begins.
3. In NORMAL only, the generating scan re-checks DEFERRED slots at the post_decode boundary: after verification/sampling/post-decode outcomes complete and any slot releases in that iteration are visible, but before the next iteration's prompt-reservation and debt pricing. It must not run in pre_decode. The scan is periodic — it runs on every post_decode boundary where active-streams membership may have changed, not once at startup or only on prompt completion — because a DEFERRED slot that was target-only decoding becomes activation-eligible when other slots release and active-streams policy permits MTP. At that boundary `inference::batching` emits the same `mtp_activation_proposal` set/order the current policy would attempt, `inference::control` emits the corresponding `mtp_activation_commit`, and `server_execution::executor` performs the mechanical attempts. After a successful activation commit and mechanical backfill, `common_speculative_begin()` is invoked exactly once at the same boundary, so the subsequent iteration's drafting phase sees a properly begun synchronized MTP cycle. The speculative owner reports outcomes; `server_inference::snapshot_reader` then publishes distinct refreshed runtime masks, synchronization facts and effective reservation maxima. The scan also finalizes, or otherwise bounds, a DEFERRED slot's hidden-state capture at the post_decode boundary after the prompt-completion transition and/or before each backfill attempt, even when MTP remains ineligible, so target-only decode does not grow the capture archive unboundedly. Cohort iterations skip activation and apply their immutable allowed profile.
4. `inference::batching` places every already-prepared replay descriptor first using its known actual atomic row count, reserves each fresh sampled candidate's worst-case verification envelope, and proposes a fair fresh member set fitting logical `n_batch`.
5. `inference::control` emits one exact `decode_preparation_commit` for that iteration, distinguishing mandatory replay blocks from fresh drafting members and authorizing any required per-member context-shift maintenance.
6. `server_execution::executor` invokes the existing bulk draft operation for exactly the committed fresh streams. Existing runtime owners return iteration-tagged `server_execution::prepared_decode_outcome` values with immutable owner, origin and exact actual rows. These outcomes cannot re-enter candidate selection or change committed membership.
7. In NORMAL or COHORT_PREFILL, `inference::batching` uses the actual decode-block cost and passive prompt candidates to propose the exact streams requiring mutating prompt reconciliation. COHORT_DECODE and `COHORT_ENTRY_DRAIN` forbid that proposal.
8. `inference::control` emits one exact `prompt_reconciliation_commit`. `server_execution::executor` delegates to existing cache/checkpoint/speculative owners for only those streams, then returns exact-stream, iteration-tagged `server_execution::prompt_reconciliation_outcome` values. No target work, admission, phase transition, fairness advancement or unrelated scheduling decision occurs during this stage.
Staged prompt reconciliation contract (no target work, admission sweep, phase transition, fairness advancement, or unrelated scheduling decision between stages):

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

9. `server_inference::snapshot_reader` publishes one global post-reconciliation snapshot. `inference::batching` derives pending work and calculates the `target_batch_proposal` from genuine residual capacity. It includes every `prepared_decode_outcome` and every still-live reconciled prompt stream with at least one legal contiguous grant.
10. `inference::control` emits the final exact `target_batch_commit` containing one `target_manifest`, or one scoped `external_target_commit`. Only these commands authorize target execution.
11. `server_execution::executor` constructs the `server_batch` and mechanical retry views from the committed `target_manifest` without discovering work or reallocating residual capacity. It executes every view and accumulates results under the same `iteration_id`.
12. After all views settle, the executor captures exact stream identities, block membership, offsets and results before release/reset can erase current-task state; it then finishes every mandatory post action and publishes one complete `server_execution::target_batch_outcome`.
13. At the resulting quiescent boundary, the driver submits `iteration_completion` and `server_inference::snapshot_reader` refreshes passive facts. Control consumes only that completion plus the snapshot, derives `R`, and commits phase/admission actions for the next iteration. Admission-only, zero-work boundary, model-mutation and terminal-failure iterations close through the same completion contract without fabricating a `target_batch_outcome`.

Mutating prompt preparation is itself authorized scheduling work. A prompt member whose cache, checkpoint, archive, memory or client-visible state was mutated cannot then be silently omitted from the committed iteration. Redistribution may occur only within the already committed prompt-preparation set and must preserve at least one legal grant for every still-live prepared prompt member.

Fresh speculative preparation never runs for a stream that the worst-case reservation did not select. Every fresh outcome is bound to the same `iteration_id` and must appear in its final `target_manifest`. Existing replay is the intentional exception: it is already-prepared slot-owned work created by the preceding verification outcome, so the next plan treats it as mandatory rather than omitting it or drafting it again. The design introduces no new prepared-but-unscheduled lifecycle.

The `target_manifest` lays the complete sampled/speculative verification-row union out as one indivisible logical prefix while retaining each stream's atomic block boundary. Ordinary prompt/sample handling already filters by `slot.i_batch` containment for the current view at `server-context.cpp:4489-4492`. Speculative verification does not: `server-context.cpp:4422-4428` supplies membership for every non-empty speculative slot, and `server-context.cpp:4466-4474` rejects a slot unless its complete `spec_i_batch` lies inside the current view. The TODO at line 4466 correctly identifies unresolved `common_sampler_sample_and_accept_n()` sub-batch compatibility.

The initial authority refactor preserves those mechanics. Every server retry view that performs speculative post-processing must contain the complete verification prefix. Retry may reduce or split only the prompt tail; it never divides the verification prefix. If the complete prefix cannot fit effective retry capacity, execution returns a typed `verification_prefix_unfit` result and takes the existing terminal cleanup/error path; it may not independently drop a member, remove speculation, slice a block, restore, despeculate, or create replacement work. Phase 3 transfers the unfit decision from legacy authority to control, where control can later commit explicit restoration/abort and replacement work. Physical `n_ubatch` microbatching inside `llama_decode()` remains unrelated.

## Speculative row accounting and lifecycle

Speculative tokens are not free target work. Draft generation creates target verification rows.

For each selected stream:

```text
verification_rows_max = 1 sampled row + maximum possible draft rows
```

The draft maximum is the effective per-stream maximum after context, remaining budget, configuration, output limits, scheduler cap and every implementation eligible for that member are applied. `common_speculative_n_max()` at `common/speculative.cpp:2780-2813` already computes the maximum across enabled implementations; cohort reservation additionally respects the immutable speculative profile. MTP-OFF excludes MTP completely, while MTP-IMMEDIATE includes its maximum from the start of planning.

Current branch defaults and bounds are materially different by implementation:

| Implementation/configuration | Current default/bound | Reservation consequence |
| --- | ---: | --- |
| Draft-model/MTP `draft.n_max` | 3 | At most 1 sampled + 3 proposals = 4 target rows |
| ngram-mod `n_max` | 64 | At most 1 sampled + 64 proposals = 65 target rows |
| ngram-mod `n_min` | 48 | A scheduler cap below 48 cannot form a valid undersized ngram proposal |
| Ngram map variant `size_m` | 48 | Implementation/map bound; not a replacement for ngram-mod `n_max` accounting |
| Ngram cache bound | 8 | Cache bound; not the proposal-row maximum |

The earlier four-row example is MTP/draft-model-specific and must not be generalized to ngram.

At eight active streams:

```text
MTP:       8 * (1 +  3) =  32 logical target rows
ngram-mod: 8 * (1 + 64) = 520 logical target rows
```

At `n_batch = 32768`, both fit comfortably. In COHORT_DECODE they consume 32 or 520 rows respectively, with no prompt competition. In NORMAL, eight maximum ngram-mod blocks leave `32768 - 520 = 32248` logical rows for prompts. The previously observed `32764` prompt rows came from one four-row MTP block; eight maximum MTP blocks would instead leave `32736` rows.

MTP-OFF cohorts, including every LoRA-active cohort, may still produce 65-row ngram blocks. Their decode batches are therefore not assumed to be small.

Dynamic speculation reserves against the maximum implementation eligible for that member and reports the actual, potentially shorter, output afterward. In a cohort, the implementation set cannot gain MTP after reservation because the frozen profile permits no activation transition.

### Participation-first ngram capacity policy

Mandatory replay blocks reserve the verification prefix first. For every fresh member, batching then computes its uncappable floor:

```text
residual_after_replay   = logical_capacity - mandatory_replay_rows
uncappable_floor(member) = 1 sampled row
                            + max(effectively allowed MTP maximum,
                                  effectively allowed other-family maximum,
                                  0)
ngram_envelope(member)   = max(uncappable_floor(member), 1 + configured_ngram_max)
```

For a require-all cohort proposal, the summed fresh floors must fit the residual or the proposal is infeasible with no selected partial set. Batching max-min water-fills the remaining logical rows toward the per-member ngram envelopes by incrementing the lowest current total allowance; stable supplied order breaks equal-allocation ties and remainder assignment. Each member's ngram cap is derived from its final allowance. NORMAL instead considers fresh members in the caller-supplied fairness order and may skip a non-fitting member; mandatory replay blocks remain selected first.

If ngram is allowed and its allocated cap is below configured `n_min`, that member uses sampled-token-only decoding for the cycle: exactly one logical row and no MTP, ngram, or other-family drafting. This literal fallback is applied after allocation; it is not merely an ngram disable that permits another draft family to re-enter through maximum pricing. The per-sequence draft-parameter path must be verified to honor the committed cap and fallback. With no replay prefix, `n_batch = 32768` and eight ordinary fresh streams, the configured ngram maximum of 64 requires no cap.

Reservation and execution rules:

Existing runtime owners report already-prepared replay descriptors as mandatory pending work. Their total row cost is one sampled base row plus `replay_token_count`, and they occupy the verification prefix before any fresh member is selected. They are not passed through bulk drafting again.
- `inference::batching` selects a fair member set whose sum of worst-case atomic blocks is at most logical `n_batch`.
- `inference::control` commits that exact set before drafting.
- `server_execution::executor` invokes the existing bulk `common_speculative_draft()` path for exactly the selected sequences. Existing runtime owners return exact iteration-tagged `prepared_decode_outcome` values. Worst-case reservation does not imply sequential drafting.
- Actual blocks may be shorter, but every prepared outcome remains selected and appears in that iteration's `target_manifest`.
- In NORMAL, decode blocks are reserved and prepared first. Only after actual lengths are known may unused residual logical capacity be proposed and committed as prompt grants.
- No additional speculative member may be prepared opportunistically to consume that residual.
- `n_batch` is the logical reservation capacity. `n_ubatch` is physical microbatch capacity and never participates in member admission or worst-case reservation.
- Fairness/rotation advances for the member set selected under worst-case reservation, not for speculative implementations internally. A homogeneous cohort reuses its single prompt-member ring if reservation ever excludes a member; it does not add a lane, decode-implementation or speculative-implementation cursor.
- The effective reservation for dynamic speculation is the maximum of its currently eligible implementations after scheduler caps and member-specific exclusions.

Each stream's sampled and speculative rows form one atomic verification block. This includes sampled-plus-ngram blocks up to 65 rows under current defaults. Current `post_decode()` checks all prepared `spec_i_batch` indices against each server view, so retry must retain the complete verification-row union in its first view. A 65-row ngram block cannot be sliced, and multiple prepared blocks cannot be distributed across separately post-processed retry views under the current mechanics.

Draft preparation also starts or retains one coupled speculative lifecycle:

```text
sampled token
+ spec_draft
+ speculative checkpoint
+ selected draft implementation and draft-context state
+ verification membership
+ rollback/replay relationship
```

Preparing a member without scheduling it would freeze that complete lifecycle across iterations and complicate cancellation, demotion, speculative-state transitions, fairness and phase advancement. Worst-case selection-before-drafting avoids those carry-over states.

Cancellation before preparation is ordinary cancellation. Once preparation begins, the exact stream is committed to the current `iteration_id` and its final `target_manifest` unless preparation or execution reaches the explicit terminal failure policy. Failure does not turn the block into opportunistically deferred prepared work.

Output/logit reservation (`n_outputs_max` and per-sequence output limits), NextN extraction, speculative verification, checkpoint rollback, acceptance and replay inherit the committed block membership and remain aligned with its target-manifest offsets.

## Target-row rules

| Phase | Sampled/verification rows | Prompt rows |
| --- | ---: | ---: |
| `NORMAL` | Allowed | Allowed under existing continuous-batching semantics |
| `COHORT_ENTRY_DRAIN` | Allowed for pre-cohort drain streams | Forbidden |
| `COHORT_INTERMISSION` | Allowed only for the exact selected multimodal task | Allowed only for that task; helper-internal media rows remain opaque |
| `COHORT_FORM` | Forbidden | Forbidden |
| `COHORT_PREFILL` | Forbidden | Allowed for cohort members |
| `COHORT_DECODE` | Allowed for cohort members | Forbidden |

These rules govern target-model rows. Auxiliary speculative work remains owned by the speculative subsystem.

`n_batch` remains logical target capacity. `n_ubatch` remains physical execution capacity. Neither is a scheduler quantum.

## Immutable cohort adapter and speculative profiles

A cohort contains exactly one immutable adapter signature:

```text
exact ordered adapter set + exact scales
```

Multiple slots with that identical static signature may share the cohort and target batch without copying adapter weights. Base/no-LoRA is the empty signature and forms its own cohort class.

The same formation commit freezes one `cohort_speculative_profile`. Its MTP component has only two values:

```text
MTP-OFF       = target-only prefill, no MTP lifecycle
MTP-IMMEDIATE = every member uses immediate MTP for the full cohort lifecycle
```

The profile is scheduling policy, not a copy of speculative runtime state. Slot masks, draft contexts, ngram state, checkpoints, verification and replay remain with their existing owners.

Policy consequences:

- Mixed active adapter signatures prevent cohort entry. Scheduling remains NORMAL until the conflicting active work clears.
- A request with another signature arriving during `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE remains queue-owned deferred until the cohort boundary.
- No adapter switch occurs during any cohort phase.
- Global `/lora-adapters` mutations are held until a cohort boundary.
- aLoRA is excluded from cohort mode initially because its effective adapter state changes at the invocation boundary.
- NORMAL retains its existing compatibility grouping, including LoRA and aLoRA mechanics; this does not create cohort lanes.
- A cohort profile never changes during PREFILL or DECODE and never mixes MTP-OFF and MTP-IMMEDIATE members.
- MTP-OFF contributes no MTP verification rows. MTP-IMMEDIATE contributes its worst-case rows to every applicable reservation from the beginning of iteration planning.
- The earlier same-iteration activation-before-reservation concern is therefore inapplicable to cohort mode. NORMAL activation ordering remains a separate migration-equivalence concern.

## Prompt-grant algorithm

Within the homogeneous cohort:

1. Begin at the last committed `active_cohort::prompt_cursor` position.
2. Enumerate live, unvisited members from the one global post-reconciliation snapshot whose tagged reconciliation outcome exposes prompt/reconciliation work; grants are calculated only after that snapshot.
3. Divide remaining `n_batch` capacity across them.
4. Give each member one contiguous grant.
5. If a member finishes early or encounters a mechanical boundary, redistribute only among members not yet visited.
6. Never revisit a sequence within the same `target_manifest`.
7. Include `proposed_next_cursor`: the successor of the first member actually granted, or the normalized supplied cursor when no grant exists.
8. Carry the proposed cursor in `target_batch_proposal`; advance the committed cursor only when control emits the corresponding `target_batch_commit`.

The one-span rule keeps target manifests and redistribution deterministic. It also remains compatible with NORMAL deferred-MTP capture at `common/speculative.cpp:1664-1677`, which records one first/last row interval per sequence and asserts if the sequence reappears in a noncontiguous span. Cohort prompt processing performs no deferred-MTP capture.

Cohort decode participation never borrows `prompt_cursor`. Participation-first ngram capping must preserve one sampled row for every active decoder. If logical `n_batch` cannot fit that minimum, control reports an explicit infeasible-capacity outcome rather than omitting a decoder through a hidden fairness rule. NORMAL retains its existing member-order/fairness behavior unless separately changed.

Nominal allocation at `n_batch = 32768` is:

| Prompt members | Initial grant per member |
| ---: | ---: |
| 1 | 32768 |
| 2 | 16384 |
| 4 | 8192 |
| 8 | 4096 |

## Stream-count and hysteresis contract

Control performs three distinct pure classifications over the complete passive snapshot:

- `independently_runnable_text`: an attached exact text stream that could advance if policy authorized it; a policy-held prompt still qualifies, while queue-owned work and dependency-blocked `WAIT_OTHER` children do not.
- `cohort_capable`: an independently runnable text stream whose task/model behavior is supported inside cohort mode. Static base/LoRA text can qualify; aLoRA, multimodal, embedding and rerank do not.
- `cohort_blocker`: attached/running work whose lifecycle or task kind forbids formation even though it is not counted in `R`, including active aLoRA, active multimodal and any still-unreviewed model-state-mutating operation.

`R` is the number of exact attached streams satisfying both `independently_runnable_text` and `cohort_capable`. It is calculated over the whole snapshot, never the largest compatible adapter subset. Control supplies one trusted, complete, ordered vector of exact stream snapshots to `inference::admission`; admission derives the returned ordered stream keys from that same vector and calculates whether it has one identical adapter signature and legal homogeneous speculative profile. It has no parallel key list or missing-member policy. Mixed active signatures produce an incompatible `formation_assessment` and remain in NORMAL; incompatible streams are never silently omitted to manufacture a qualifying scope. Effective aLoRA remains a raw fact and a control-owned cohort blocker, not an admission incompatibility verdict.

`server_inference::snapshot_reader` reports exact passive current-task lifecycle, task-kind, dependency, adapter/aLoRA and capability facts. Control alone classifies lifecycle/task-kind blockers and derives `R`; admission alone assesses profile compatibility for the exact supplied scope; control alone commits entry or exit. There is no event-maintained stream counter or second threshold authority to drift from slot state.

For `n_cmpl > 1`, the parent is the only runnable prompt stream while its children are `WAIT_OTHER`. At `server-context.cpp:4434-4453`, completion of the shared parent prompt copies state to the children and makes the parent and children independently runnable. Only then can those completion streams collectively satisfy the entry threshold. Thus one request can trigger cohort mode, but request cardinality itself is never counted.

Let:

```text
E = configured entry_streams
X = configured exit_streams, where 0 < X < E
R = count(independently_runnable_text && cohort_capable)
```

The hysteresis rule is mode-relative:

- In NORMAL, remain NORMAL while `R < E`; enter pre-cohort scheduling only when `R >= E`, the control-owned blocker set is empty, and admission returns a compatible assessment for the exact scope.
- In a cohort phase, remain cohort-controlled while `R > X`; terminate the cohort lifecycle when `R <= X`. A decode-side exit enters the multimodal boundary decision before FORM or NORMAL.
- Entry or exit is immediate at the controller boundary: it occurs in the same scheduling turn after the preceding `target_batch_outcome` closes its iteration, the passive snapshot refreshes, and control derives `R`, but before any further preparation or target invocation. It never reacts to a partial `batch_view`.
- The exit decision is committed after completion/cancellation outcomes and before the next preparation or `target_batch_commit`. It never interrupts a prepared or executing target manifest.
- On exit, clear `active_cohort` and retain every surviving slot, sampled token, speculative lifecycle, archive, checkpoint, cache and replay relationship unchanged. Survivors remain held through any selected multimodal intermission, then continue under FORM or NORMAL.
- A surviving exact stream may later enter a new cohort under a new monotonic cohort ID if `R` reaches `E` again.

The concrete three-stream observation is a worked example, not policy constants:

- With example `E = 3`, if two prompt streams are already prefilling and admission attaches a third compatible prompt stream, the count reaches `E` before the next target batch. Control forms one cohort containing all three. Earlier finishers wait at the prompt barrier until the remaining member completes prefill, then all live members decode.
- With example `E = 3`, if two streams are decoding and a third attached prompt stream raises the count to `E`, control enters `COHORT_ENTRY_DRAIN` and holds that prompt. Example `X = 1` keeps draining when the first decoder finishes because `R = 2 > X`; after the second finishes, `R = 1 <= X`. Example `X = 2` reaches the boundary after the first decoder finishes. With no ready multimodal task, the zero-work intermission lets NORMAL resume immediately, producing the previously described full-drain or mixed decode/prefill behavior. With a ready multimodal task, that one task runs exclusively first. The configured exit threshold deliberately selects the decode boundary; the queue state selects whether the intermission does work.

FORM does not require another task to be admitted. When the threshold-crossing stream was attached by the immediately preceding NORMAL transaction, FORM may close with an empty queue lease and atomically freeze the already-attached prompt pairs in that same scheduling turn.

## Pre-cohort drain and uniform-work formation contract

Crossing `R >= E` does not create a cohort. It creates only a control-owned entry intent represented by global phase `COHORT_ENTRY_DRAIN` or a direct transition to FORM when no decode-family work exists. `active_cohort` remains absent, no `cohort_id` is allocated, and no cohort profile is applied until FORM succeeds.

The work-family predicates are phase-neutral:

```text
decode_family_pending = mandatory replay
                     || pending sampled-token evaluation
                     || fresh speculative verification candidate/block

prompt_family_pending = unresolved prompt reconciliation
                     || prompt-token/last-logit evaluation work
```

The uniform-start rules are:

1. Control evaluates entry only after `iteration_completion`; an already executing mixed NORMAL target manifest always finishes first.
2. If any attached cohort-capable incumbent has decode-family pending work, control enters `COHORT_ENTRY_DRAIN`. Every such stream is inside the drain scope; there is no decoder “outside” the prospective cohort decision.
3. ENTRY_DRAIN authorizes only replay, sampled-token and verification work. It holds every partial/new prompt unchanged, performs no prompt reconciliation/grant, creates no `active_cohort`, and keeps new inference arrivals queue-owned.
4. A decoder that produces another sampled token after an accepted output still has decode-family pending work. It remains in ENTRY_DRAIN until the request completes/cancels; finishing one token does not make FORM eligible.
5. If drain outcomes reduce `R` to `X` or below, control abandons entry intent and follows the configured lower-threshold INTERMISSION/NORMAL behavior without creating a cohort.
6. FORM becomes eligible only when decode-family pending work is zero across the complete exact attached scope and `R > X`. Its proposed members expose prompt-family work only.
7. Any sampled input, replay descriptor, prepared/fresh verification block, or generating decoder in the proposed scope blocks FORM. Admission cannot omit that stream to manufacture an all-prompt cohort.
8. FORM binds `active_cohort` only after its exact scope receives a compatible `formation_assessment` and attachment results remain consistent with that scope. The same atomic decision transitions to `COHORT_PREFILL`; committed initialization must then succeed before any target work, using the failure/recount path already defined by the admission contract.
9. If `R >= E` is observed with no decode-family pending work, control may move directly from NORMAL to FORM; it still does not create the cohort before FORM commit.

“All prefill” therefore means one uniform prompt/reconciliation work family, not equality with a categorical `SLOT_STATE_PROCESSING_PROMPT` value. Partially prefilled streams qualify through remaining prompt-family work. A fully cached prompt that still owes mandatory last-token/logit evaluation also remains prompt-family work. A stream whose prompt completed and now owns a sampled input is decode-family work and must drain rather than join the prefill cohort.

Only `COHORT_PREFILL` and `COHORT_DECODE` own a non-empty `active_cohort`. NORMAL, ENTRY_DRAIN, INTERMISSION and the pre-bind portion of FORM have none. This makes it impossible to execute a decoder outside an active cohort while simultaneously claiming that a prompt cohort has begun.

## Multimodal boundary contract

Multimodal is scheduled as an exact task, not as exposed helper-internal media batches:

- An already attached/running multimodal task prevents cohort entry. Control remains in NORMAL, closes competing inference admission, and gives that exact task exclusive target authority until it completes or is cancelled; it is not imported into `COHORT_ENTRY_DRAIN`.
- A multimodal task arriving during `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE remains queue-owned. It cannot interrupt a cohort or consume rows beside cohort work.
- When a completed or partially drained decode set reaches `R <= X`, control ends any active cohort lifecycle and enters `COHORT_INTERMISSION` before NORMAL mixed work or FORM/PREFILL.
- At most one oldest ready, mechanically placeable multimodal task is selected from `server_queue` for that intermission. Control owns the class-priority decision; the queue retains task storage, cancellation visibility and order among multimodal tasks.
- Selection uses the existing lease transaction: queue lease, reservation-aware placement, control acceptance, mechanical attachment, exact-pair reporting, atomic `intermission_task` bind, then lease resolution. No target work occurs between attachment and that bind.
- Once admitted, that exact `stream_key` owns target execution exclusively until the task completes or is cancelled. Its ordinary text/decode work uses single-stream `target_manifest` values. Its media path uses a task-scoped `external_target_commit` covering the helper calls for that task; `mtmd_helper_decode_image_chunk()` retains its internal chunk packing and `llama_decode()` calls without exporting each internal row or batch to `inference::control`.
- Survivors from the partially drained text set remain attached and held. No survivor draft preparation, verification block or target row runs during the multimodal task window.
- After that one task finishes, control leaves INTERMISSION even if more multimodal tasks are queued. If any held text decoder survives the partial drain, it returns to NORMAL so mixed decode/prefill policy can resume. Only with no surviving decoder may it proceed directly to FORM when a prompt-cohort proposal is available; otherwise it returns to NORMAL. This one-task boundary grant prevents a multimodal queue from starving text cohorts.
- If no eligible multimodal task is waiting, INTERMISSION is a zero-work control transition in the same scheduling turn.

The task is the persistent priority unit, while target authority is still committed action by action: each ordinary single-stream target manifest or task-scoped helper operation is committed by control before execution. No broad executor-owned task window is introduced.

## Phase-transition table

Rows are evaluated top-to-bottom with first-match semantics. The predicates below are deliberately disjoint at the policy boundaries: attached multimodal exclusivity wins before ordinary NORMAL work, and FORM entry requires an admission-compatible, decoder-free exact scope.

| Current phase | Condition | Action | Next phase |
| --- | --- | --- | --- |
| `NORMAL` | An attached multimodal task remains live | Close competing inference admission, commit target work only for that exact task, and defer cohort entry until it releases | `NORMAL` |
| `NORMAL` | No attached multimodal task is live, and cohort mode is disabled or `R < E` | Emit current generation-first continuous-batching policy | `NORMAL` |
| `NORMAL` | No attached multimodal task is live; `R >= E`; blocker set is empty; admission reports exact-scope compatibility; and runnable decode-family pending work exists | Record pre-cohort entry intent, close ordinary inference admission, and authorize only proposed replay/sampled/verification drain work | `COHORT_ENTRY_DRAIN` |
| `NORMAL` | No attached multimodal task is live; `R >= E`; a lifecycle/task blocker exists or admission's complete-scope assessment is incompatible | Remain in NORMAL until the blocker or incompatible state clears | `NORMAL` |
| `NORMAL` | No attached multimodal task is live; `R >= E`; blockers are empty; admission reports a compatible exact-scope assessment; and no runnable incumbent decode-family pending work remains | Close ordinary admission and begin a formation transaction containing the attached prompt incumbents | `COHORT_FORM` |
| `COHORT_ENTRY_DRAIN` | After `iteration_completion` and refreshed snapshot, `R <= X` | Abandon entry intent, preserve surviving text state, and open the decode-boundary priority decision | `COHORT_INTERMISSION` |
| `COHORT_ENTRY_DRAIN` | `R > X` and any incumbent decode-family pending work remains | Re-derive the complete exact live set; authorize only replay/sampled/verification work and hold all prompt-family work | `COHORT_ENTRY_DRAIN` |
| `COHORT_ENTRY_DRAIN` | `R > X` and decode-family pending work is empty across the complete exact live scope | Seed FORM exclusively from held prompt-family/dependency facts and open one bounded queue lease | `COHORT_FORM` |
| `COHORT_INTERMISSION` | The selected multimodal task remains live | Emit only that task's single-stream `target_batch_commit` or task-scoped `external_target_commit` | `COHORT_INTERMISSION` |
| `COHORT_INTERMISSION` | No task has been served at this boundary and one eligible multimodal task is ready | Lease/admit the oldest such task and commit it as the exclusive intermission task | `COHORT_INTERMISSION` |
| `COHORT_INTERMISSION` | The selected task completed/cancelled, or no eligible multimodal task was ready; a held text decoder survives | Reopen NORMAL so mixed decode/prefill scheduling may resume | `NORMAL` |
| `COHORT_INTERMISSION` | The selected task completed/cancelled, or no eligible multimodal task was ready; no text decoder survives | Open FORM if a prompt-cohort proposal is available; otherwise reopen NORMAL | `COHORT_FORM` or `NORMAL` |
| `COHORT_FORM` | Formation sweep remains open | Perform no target work | `COHORT_FORM` |
| `COHORT_FORM` | Sweep closes with resulting `R <= X` | Allocate no cohort ID; resolve attachment/lease results into NORMAL and preserve all surviving state | `NORMAL` |
| `COHORT_FORM` | Sweep closes with resulting `R > X`, zero decode-family pending work across the complete scope, and one compatible admission-owned `formation_assessment` | Minimally attach and report exact pairs; atomically bind ID, membership, adapter/profile values and cursor; then mechanically apply that profile and restore cache before target work | `COHORT_PREFILL` |
| `COHORT_PREFILL` | After the complete `target_batch_outcome`/cancellation refresh, `R <= X` | End the active cohort, clear its controller-owned lifecycle state, and preserve survivors for NORMAL scheduling | `NORMAL` |
| `COHORT_PREFILL` | `R > X` and any live member has unresolved reconciliation or nonzero prompt/reconciliation work | Commit reconciliation as required, then distribute contiguous prompt grants from the tagged global snapshot | `COHORT_PREFILL` |
| `COHORT_PREFILL` | `R > X` and every live exact stream is reconciled with zero prompt/reconciliation work | Close the prompt barrier; already visible sampled-token work remains held until DECODE | `COHORT_DECODE` |
| `COHORT_DECODE` | After the complete `target_batch_outcome`/cancellation refresh, `R <= X` | End and clear the active cohort lifecycle, preserve survivors, and open the decode-boundary priority decision | `COHORT_INTERMISSION` |
| `COHORT_DECODE` | `R > X` and cohort members remain live | Authorize proposed replay/sampled/verification blocks without adapter switching | `COHORT_DECODE` |

New inference arrivals during `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE remain queue-owned. A ready multimodal task may receive the one-task INTERMISSION grant at the decode boundary; text tasks wait for FORM or the subsequent return to NORMAL.

## Early prompt completion

When a member's final prompt target row succeeds, the existing runtime must consume its logits before another target invocation. Prompt completion is expressed as an outcome and new pending sampled work, not as a controller-owned member phase.

NORMAL prompt-completion ordering is:

```text
prompt target outcome
    -> control activation commit (prompt-completion path; debt never decides MTP eligibility or activation timing)
    -> server_execution::executor performs the mechanical activation attempt
    -> common_speculative_begin() exactly once
    -> sample and perform existing client/stopping processing
    -> complete target_batch_outcome publishes output_committed_count
       plus pending sampled input at a quiescent progress refresh
    -> next iteration lineage

```

Cohort prompt completion skips activation because the profile is already frozen:

```text
prompt target outcome
    -> common_speculative_begin() exactly once under MTP-OFF or MTP-IMMEDIATE
    -> sample and perform existing client/stopping processing
    -> complete target_batch_outcome publishes zero prompt work
       plus pending sampled input
```

The slot may mechanically become `GENERATING`, but neither control nor batching uses that mutation as the barrier predicate. During COHORT_PREFILL the pending sampled input remains visible but unauthorized. When every live exact stream is reconciled with zero prompt work, COHORT_DECODE authorizes that sampled input exactly once through the existing insertion path.

Parent/child completions follow the same barrier. Existing parent state copying and immediate sampling of each child remain intact, and refreshed child facts become policy-visible only after the complete `target_batch_outcome` closes the iteration.

## Cohort speculative-profile contract

Formation commits the complete profile before prompt-cache restore, attachment, or prompt work:

- MTP-OFF removes MTP from every incoming mask and selects target-only prefill for every member.
- MTP-OFF performs no NextN hidden-state capture, DRAM archive allocation/copy, deferred backfill, activation attempt/scan, or MTP verification.
- MTP-IMMEDIATE is legal only when every member can enter immediate MTP at formation and retain it through PREFILL and DECODE.
- MTP-IMMEDIATE capability requires either an immediate-compatible cache restore or enough context to discard the incompatible restore and prefill immediate from scratch. Target-only restore fallback is not legal under an IMMEDIATE profile.
- MTP-IMMEDIATE capability also excludes a stream whose declared prompt/generation lifetime can require a stateful context shift that would demote MTP. If an unplanned runtime condition still requires such a demotion, that exact stream follows the existing request failure/completion outcome before the shift; the cohort does not silently continue with a mixed profile.
- If homogeneous immediate MTP cannot be established, formation chooses MTP-OFF; it does not create a deferred cohort.
- LoRA-active cohorts are always MTP-OFF. Ngram remains independently eligible because it does not depend on a LoRA-adapted draft-model context.
- No cohort phase changes the profile or invokes `try_activate_deferred_mtp()`.

This is supported by the current backfill mechanics. `common/speculative.cpp:1573-1576` requires target `pos_max` to equal the archive `pos_end`. After even one target-only decode, later backfill returns invalid; `server-context.cpp:3530-3533` then drops the archive. The legacy repeated generating-slot scan at `server-context.cpp:3614-3617` does not make genuine post-advance activation valid, and both legacy activation call sites (`server-context.cpp:3614-3618` and `4512-4518`) are deleted in Phase 5 and replaced by the single post_decode generating scan owned by control; mechanical backfill remains in server_execution.

NORMAL retains the existing immediate/deferred/target-only policy, archive lifecycle and activation timing. Migrating that timing into `inference::control` must preserve NORMAL behavior; it does not authorize cohort activation.

Lower-threshold exit occurs only after every `batch_view` and mandatory post action for the committed `target_manifest` settles, so no freshly drafted unexecuted block crosses the transition. A replay block created by that complete outcome's partial acceptance is different: it remains slot-owned, may be held unchanged through INTERMISSION, and becomes mandatory prefix work in the first subsequent NORMAL plan. The cohort profile constraint otherwise ends, but authoritative slot/speculative state remains intact. Dynamic NORMAL MTP policy resumes for newly admitted or otherwise mechanically eligible work. Any MTP-OFF survivor whose target context advanced through prefill or decode without matching MTP capture remains MTP-OFF until completion unless future midstream reconstruction is implemented; only a survivor on which no target work occurred may be reconsidered normally. Ngram eligibility is recalculated normally after the boundary.

## Replay and checkpoints

`inference::control` treats the existing runtime's replay descriptor as mandatory pending decode-family work belonging to the same `(slot, task)` member. It does not inspect acceptance length, checkpoint contents, draft rollback, partial sequence restoration, or replay tokens.

Existing `post_decode()` mechanics establish the resulting slot and speculative state. After every `batch_view` settles, `server_execution::executor` captures current-task identity before release/reset and publishes one complete `target_batch_outcome` after all mandatory post actions finish. The next committed control action prices the reported replay block before fresh work unless the same outcome triggers lower-threshold exit. At exit, replay remains visible but unauthorized through any intermission and is mandatory on return to NORMAL.

The runtime reports either `replay_token_count`, priced as one sampled base row plus `replay_token_count`, or total `replay_rows` with unambiguous naming. It is packed before fresh draft selection, remains slot-owned, and is not passed to `common_speculative_draft()` again. This preserves the sampled token, retained `spec_draft`, checkpoint restoration and acceptance/replay relationship without adding controller-owned speculative state.

Prompt-cache restore, checkpoint restore and context shifting remain executor mechanics. aLoRA boundaries remain NORMAL-only executor mechanics and cannot enter cohort preparation.

## Non-cohort work

The initial text-cohort policy handles the following outside text cohorts:

- Multimodal prompts.
- Embeddings.
- Reranking.
- aLoRA requests.

Multimodal prompt processing directly invokes target decode through `server_slot::process_mtmd_chunk()` and `mtmd_helper_decode_image_chunk()` at `tools/server/server-context.cpp:945-1032`; the caller may process a consecutive media run at `tools/server/server-context.cpp:4174-4205`. The controller contract therefore names the exact task as the scheduling unit and leaves the helper's media chunk aggregation, encoding, internal batch sizing and target calls opaque. It does not manufacture logical `server_batch` rows for helper internals.

An incumbent multimodal task finishes under exclusive NORMAL authorization before cohort entry. While cohort policy is in `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE, a queued multimodal task can be admitted only through the one-task decode-boundary INTERMISSION described above; ordinary NORMAL admission remains available outside that interval. Multimodal never executes in `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE and never joins a text cohort.

Embedding and rerank remain NORMAL-only batch work. Their incumbent/queued boundary policy remains in the decision register; the accepted multimodal policy does not silently decide it for them.

## Required invariants

1. Every target-model invocation is authorized by `inference::control` as either one `target_batch_commit` or one exact scoped `external_target_commit` carrying an immutable `iteration_id`.
2. Every logical target row belongs to a `stream_key` named in the committed `target_manifest`.
3. No downstream executor scans slots to find additional work.
4. Cohort prefill batches contain prompt target rows only.
5. Cohort decode batches contain sampled/verification target rows only.
6. Each prompt sequence appears in at most one contiguous span per `target_manifest`.
7. A speculative verification block is atomic; under current post-decode mechanics, retry keeps the complete prepared verification union in its first processed view.
8. Frozen-cohort membership uses exact `(slot_id, task_id)` identity.
9. Released slots do not promote inference work without a control-committed admission window.
10. Queue leases remain queue-owned and cancellation-visible until mechanical attachment establishes the queue-to-slot ownership cutover.
11. Mutating preparation occurs only for members named by a committed preparation action.
12. Early prompt completion is sampled exactly once.
13. No cohort phase attempts deferred MTP activation or backfill.
14. Cohort transitions do not reinterpret speculative, cache, checkpoint, or replay state. The committed formation profile alone may mechanically discard MTP state incompatible with MTP-OFF before cohort work begins.
15. `n_ubatch` never influences scheduling phase progression.
16. Every cohort member has the exact frozen adapter signature.
17. No adapter switch or global adapter mutation occurs during `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE.
18. LoRA-active cohort members never carry, capture, backfill, activate or execute MTP state.
19. Ngram speculation remains independently eligible for LoRA-active cohorts.
20. The sum of selected worst-case verification reservations never exceeds logical `n_batch`.
21. Draft preparation runs only for the control-committed reserved member set.
22. Every prepared decode outcome appears in that iteration's committed `target_manifest`.
23. Actual shorter drafts may free NORMAL prompt capacity but may not trigger opportunistic preparation of another speculative member.
24. Output/logit limits, NextN, verification, rollback, acceptance and replay use the same committed block membership and offsets.
25. Worst-case reservation uses the maximum across every speculative implementation eligible for that member, not the MTP maximum.
26. Ngram capacity pressure caps proposals fairly before excluding cohort members.
27. A committed cohort atomically binds one monotonic `cohort_id`, its initial ordered `stream_key` values, immutable adapter and speculative profiles, and initial prompt cursor before target work resumes.
28. Cancellation or completion may shrink `active_cohort::members` without changing its ID while `R > X`; reaching `R <= X` ends and clears that cohort lifecycle.
29. Queue `lease_id`, task ID, slot ID, `stream_key`, `cohort_id`, and `iteration_id` are never conflated.
30. An allowed ngram cap below configured `n_min` produces exactly one sampled logical row for that member/cycle and suppresses MTP, ngram and other-family drafting.
31. Under current post-decode mechanics, retry capacity fits the complete prepared verification prefix in the first processed view; no atomic block, including a maximum 65-row ngram block, is sliced.
32. Cohort entry and exit compare control-derived `R` only against configured `E` and `X`; requests, largest compatible subsets, raw occupied slots and fixed numeric constants are not threshold units.
33. After the complete `target_batch_outcome` reduces `R` to `X` or below, control ends cohort policy before the next preparation or target batch and preserves surviving streams unchanged through the boundary decision.
34. An attached multimodal task blocks cohort entry and owns exclusive NORMAL target authority until it completes or is cancelled.
35. Multimodal work never executes in `COHORT_ENTRY_DRAIN`, FORM, PREFILL or DECODE; a queued task can run only as the one exact task selected at a decode-side `R <= X` INTERMISSION.
36. The intermission selects at most one oldest eligible multimodal task, preserves queue ownership/order, and holds every surviving text stream without preparation or target rows.
37. Multimodal task identity is the controller scheduling scope. Helper-internal media chunks, encoded batches and target calls remain executor mechanics under the committed task-scoped operation.
38. Completion/cancellation of the selected multimodal task ends that intermission even when another multimodal task is queued.
39. One homogeneous speculative profile is committed before cache restore, attachment, or prompt work and remains immutable for the cohort lifecycle.
40. MTP-OFF members create no MTP capture/archive/backfill/activation state or MTP verification rows.
41. MTP-IMMEDIATE applies to every cohort member from formation through decode; a cohort never mixes immediate and OFF members.
42. Dynamic mid-decode MTP reactivation is outside the supported cohort lifecycle.
43. Only global cohort policy has an explicit scheduling phase; control stores no per-member lifecycle stage, progress tuple, pending-work set, reconciliation result, sampled token, prepared block, replay flag, or physical position.
44. Logical current-task progress is the lifecycle-gated `(reconciled_prompt_coverage, output_committed_count)` tuple. Prepared extent and physical KV/cache positions remain distinct and may move independently.
45. Reconciliation runs only for exact streams named by `prompt_reconciliation_commit` and returns `prompt_reconciliation_outcome` values before batching proposes grants.
46. `server_inference::snapshot_reader` reports passive task/dependency/capability facts; `inference::control` alone classifies streams, derives lifecycle/task blockers and `R`, while `inference::admission` alone calculates the exact-scope adapter/speculative `formation_assessment`. Control only commits or rejects that assessment.
47. Pending work, priced proposals, and authorized work are distinct; policy-held work remains visible without becoming authorized.
48. One `iteration_id` may correlate several committed preparation actions, but only its `target_batch_commit` authorizes target execution. An immutable lineage handle is passed through preparation, retry views, post-decode and outcome reporting.
49. Fresh prepared-block descriptors are execution outcomes bound to the selected set; they cannot trigger member reselection or candidate discovery.
50. Policy consumes no partial command or `batch_view` result. Phase, barrier, `R`, admission, and next-work decisions wait for one `iteration_completion`; target iterations require its complete `target_batch_outcome` payload.
51. Outcome reporting captures exact pairs, membership and offsets before slot release can destroy current-task identity.
52. Runtime speculative eligibility/synchronization, the immutable cohort allowed profile, and the effective post-activation reservation input remain distinct authorities.
53. Mechanical lifecycle interpretation of `SLOT_STATE_*` is confined to source translation and response/outcome mechanics; it never independently selects work after target-authority takeover.
54. If retry cannot fit the complete verification prefix, execution returns a typed `verification_prefix_unfit` result and takes the existing terminal cleanup/error path; it performs no uncommitted membership, speculation, or replacement-work change.
55. `active_cohort::members` retains stable attachment order; pruning and prompt-cursor normalization follow the exact algorithm in this document.
56. `prompt_cursor` is never used for decode/speculative stream selection.
57. The existing `server_queue` is the queue component and type; no conflicting `server_queue` namespace is introduced.
58. Cache restore and speculative-profile initialization are executed only by `server_execution` under an exact control command, never hidden inside passive snapshot translation or slot placement.
59. `R >= E` alone never creates `active_cohort`, allocates a `cohort_id`, or applies a cohort profile.
60. `COHORT_ENTRY_DRAIN` contains no active cohort and authorizes every attached decode-family stream in its complete exact scope while holding all prompt-family work.
61. FORM cannot bind a cohort until decode-family pending work is zero across the complete exact formation scope; admission cannot omit a decoder to manufacture compatibility or a uniform prompt set.
62. Only `COHORT_PREFILL` and `COHORT_DECODE` have a non-empty `active_cohort`, and every active-cohort member belongs to the same authorized work family for that phase.
63. If `R <= X` during entry drain, control abandons entry intent without allocating a cohort identity and reaches the decode-boundary INTERMISSION/NORMAL decision.
64. `server_context::update_slots()` is the sole assembler of `iteration_completion`; executor outcomes are typed inputs to that closure and cannot independently close an iteration or advance policy.

## Critical-path change boundary

The durable replacement requires changes to:

- The queue drain/admission transaction boundary.
- Cancellation-aware queue lease lifecycle.
- Deferred promotion from slot release.
- Per-task speculative occupancy planning.
- `update_slots()` becomes the exact mechanical snapshot/dispatch/outcome pump and loses every scheduling-policy branch.
- Opportunistic selection inside `pre_decode()`.
- The current single-pass coupling of STARTED reconciliation and immediate prompt-row grants; reconciliation must become an exact-stream committed stage followed by one global snapshot and control-committed grants.
- Direct scheduling uses of `SLOT_STATE_*` for generating selection, prompt membership/grants, and context-shift maintenance. The exact Phase 3 legacy deletion catalogue: generating selection and speculative preparation `tools/server/server-context.cpp:3629-3745`; prompt membership, compatibility, reconciliation and grants `3754-4292`; context-shift maintenance selected from generating state `3546-3612`. Scheduling uses of `SLOT_STATE_*` are deleted at Phase 3 takeover; mechanical lifecycle/response uses are retained in server_inference and post-decode mechanics; the sole temporary exception is the isolated legacy NORMAL MTP activation timing (`3614-3618`, `4512-4518`) removed atomically in Phase 5.
- Independent NORMAL MTP activation decisions in `pre_decode()` and `post_decode()`; both legacy call sites (`server-context.cpp:3614-3618` and `4512-4518`) are deleted and replaced by one periodic post_decode generating scan that runs after verification/sampling completes and releases are visible, before next-iteration reservation pricing. Existing NORMAL behavior is preserved while timing authority moves to control, and cohort paths perform no scan.
- Direct multimodal target invocation authorization.
- Multimodal NORMAL admission closure and decode-boundary queue selection.

The following should remain mechanically intact:

- `server_batch` storage, rendering, and views.
- Existing speculative membership, `spec_i_batch` indexing, and whole-prefix `post_decode()` processing; the refactor changes only prefix layout and prompt-tail retry partitioning.
- Target `llama_decode()`.
- Physical microbatch splitting.
- NextN extraction.
- MTP and ngram implementations.
- Sampling and token processing.
- Speculative verification, rollback, and replay.
- Prompt-cache and checkpoint implementations.
- Slot-selection algorithms.
- LoRA and aLoRA mechanics.
- Parent/child state copying.
- Response handling.
- Lifecycle use of `SLOT_STATE_*` inside the mechanical fact translator and existing response/outcome machinery.

Prompt setup code will need to be extracted from the current monolithic `pre_decode()`, but its cache, checkpoint, context-shift, aLoRA, and media mechanics do not need to be redesigned. The extraction changes authority and sequencing: control emits an exact `prompt_reconciliation_commit`; existing owners mutate; tagged outcomes feed a global snapshot; batching proposes grants; control emits the `target_batch_commit`.

## Configuration

The minimal external configuration surface is:

```text
--cohort-batching-threshold E
--cohort-batching-exit-threshold X
```

- With neither paired option configured, cohort mode is absent and the controller preserves NORMAL behavior; disabling is not encoded as a numeric threshold.
- Enabling cohort mode requires explicit `E` and `X` satisfying `0 < X < E`; the controller contains no fixed entry or exit stream count.
- Both thresholds compare `R = count(independently_runnable_text && cohort_capable)`, never requests, largest compatible subsets, raw occupied slots or boundary multimodal tasks.
- No prompt-quantum option.
- Existing `--cont-batching` controls NORMAL policy only.
- Existing `--spec-active-limit` and `--spec-mtp-deferred` retain their NORMAL semantics and do not affect the immutable cohort profile.

## Observability

Expose:

- Current controller phase.
- Current independently runnable stream count `R`, configured entry `E` and exit `X`, and the reason for each threshold transition.
- Pre-cohort entry intent, complete exact drain scope, decode-family blocker count/reasons, prompt-family held count, and the first phase entered after a successful cohort bind.
- Active monotonic `cohort_id` in structured logs and debug APIs.
- Monotonic `iteration_id` and committed target-manifest identity in structured logs/debug APIs.
- `iteration_completion` kind and terminal reason, distinguishing target, external, model-mutation, admission-only, zero-work and failure closure.
- Exact global cohort membership plus raw dependency/task-kind facts used by control to derive `R`.
- Per-member `reconciled_prompt_coverage`, `output_committed_count`, pending sampled input, derived pending-debt class (prompt/reconciliation, sampled-token, fresh-verification, mandatory-replay, none) and authorization/hold reason.
- Tagged reconciliation and prepared-block outcomes, including fresh/replay origin and exact row cost.
- Physical target/draft positions explicitly marked diagnostic and non-semantic.
- Frozen adapter signature, reported without duplicating adapter weight state.
- Queue `lease_id` on admission transaction events, distinct from `cohort_id`.
- Logical rows planned and emitted by kind.
- Per-member maximum verification reservation and actual sampled/verification rows.
- Per-member eligible implementation maximum, configured/effective ngram cap and sampled-only fallback reason.
- Reserved-versus-actual decode rows and NORMAL residual capacity assigned to prompts.
- Per-slot prompt grant and actual rows.
- Members held at the prefill barrier.
- Projection refresh cause and complete-lineage outcome: committed advancement, prepared retraction, replay creation/consumption, completion, cancellation or release.
- Phase transition counts and elapsed time.
- Arrivals held outside the current cohort until the decode-boundary INTERMISSION decision, a FORM window or return to NORMAL.
- INTERMISSION predecessor cohort ID or pre-cohort `COHORT_ENTRY_DRAIN` marker, eligibility, selected exact multimodal task, queue wait, exclusive task duration, helper-call/chunk totals and completion/cancellation outcome.
- Frozen cohort speculative profile, profile-selection reason, MTP-OFF versus MTP-IMMEDIATE cohort counts, suppressed MTP capture/archive/backfill work, and MTP/ngram logical row composition.

`LLAMA_BATCH_DEBUG=1` continues to report physical microbatch splitting. Controller telemetry reports logical scheduling composition. It never publishes a passive snapshot between `batch_view` values of one iteration.

Neither `iteration_id`, `cohort_id`, `lease_id`, `task_id`, nor exact stream identity is a Prometheus label. Aggregate metrics may count pending/authorized rows by global phase and work class, held/blocked work, committed advances, prepared retractions, refresh causes, and iteration/outcome mismatches. High-cardinality identities are intended for structured tracing, cohort-makespan attribution, row-composition logs, cancellation reports, and slot-reuse diagnosis.

## Implementation decomposition

The separately maintained phased plan defines the migration. Its governing rule is:

```text
admission/batching component calculates an exact proposal
    -> inference::control emits the corresponding exact commit type
    -> server adapter applies mechanically
```

Every authority transfer is atomic within its phase. A dormant proposal calculator is permitted before takeover; dual-running or fallback scheduling policy is not. Rollback after dependent phases land proceeds in reverse dependency order rather than by arbitrary individual commit reversion.

## Regression catalogue

Control/admission/batching policy tests:

- Passive raw facts never contain a pre-decided cohort-eligibility/`R` boolean; control deterministically derives the eligible exact set and `R`.
- Current-task lifecycle gates ignore stale reused-slot `n_decoded`, `sampled` and `has_next_token` during WAIT_OTHER, STARTED, unreconciled/incomplete prompt and DONE_PROMPT-before-sampling states.
- Admission consumes one trusted complete ordered snapshot vector, derives the same ordered exact keys, and owns no parallel-key or missing-member policy; effective aLoRA blocking remains control-owned.
- NORMAL compatibility preserves exact source operation identity, including COMPLETION versus INFILL, independently from input kind and multimodal input.
- Reconciled prompt coverage plus output-committed count remains monotonic for one exact live task while prepared speculative extent retracts and physical prompt/KV positions move independently.
- Pending work, priced proposals and authorized work remain separate; barriers and INTERMISSION hold visible work without erasing it.
- NORMAL generation-first behavior.
- NORMAL continuous-batching behavior.
- No entry while independently runnable stream count is below configured `E`; entry occurs when admission or parent/child activation raises it to `E` or above.
- Threshold crossing records entry intent but allocates no cohort ID and creates no `active_cohort` until FORM commits a uniform prompt-family scope.
- A mixed NORMAL iteration already in flight completes its full `iteration_completion` before entry-drain policy is evaluated.
- When threshold crossing observes partial/new prompt work beside one or more decoders, `COHORT_ENTRY_DRAIN` holds every prompt unchanged and includes every attached decode-family stream in the drain scope.
- A decoder that samples another token remains decode-family pending and keeps entry drain active until completion/cancellation or the lower exit threshold; one accepted token cannot make FORM eligible.
- FORM is rejected while any exact-scope stream owns sampled input, mandatory replay, prepared/fresh verification work, or another generating decode obligation; admission cannot omit that stream.
- A fully cached prompt still requiring last-token/logit evaluation is prompt-family eligible, while a prompt-complete stream with sampled input is decode-family and must drain.
- If no decode-family work exists when `R >= E`, control may transition directly to FORM, but still binds no cohort before FORM commits.
- If entry-drain outcomes reduce `R <= X`, entry intent is abandoned, no cohort identity is consumed, and the intermission/NORMAL boundary runs.
- Requests and occupied slots are not substituted for independently runnable stream count.
- `WAIT_OTHER` children do not count until shared-prompt state copying makes them independently runnable.
- One `n_cmpl > 1` request can trigger entry only when enough parent/child completion streams become independently runnable to satisfy `E`.
- A cohort remains active through the hysteresis band while `R > X` and exits at the first control boundary where `R <= X`.
- Exit is committed before the next batch and retains all executor/speculative state. With no ready multimodal task, the zero-work intermission permits NORMAL mixed prompt/decode scheduling in the same scheduling turn.
- Lower-threshold exit carries no freshly drafted unexecuted block. Outcome-created replay remains slot-owned, may be held through INTERMISSION, and is mandatory in the first subsequent NORMAL verification prefix. An MTP-OFF survivor whose target context advanced without MTP capture remains OFF; only no-target-work survivors and newly admitted or otherwise mechanically eligible NORMAL work may resume existing dynamic policy.
- A surviving exact stream may later receive a new cohort ID upon re-entry.
- Frozen admission during drain, prefill, and decode.
- New arrivals never join an already frozen cohort; they remain queue-owned until the decode-boundary INTERMISSION decision, a FORM window or return to NORMAL.
- Cohort creation commits the speculative profile before cache restore/attachment, then atomically binds the next monotonic ID, exact initial pairs, immutable adapter/profile values, and initial cursor before any target work.
- Cohort ID remains stable through PREFILL-to-DECODE and membership pruning while `R > X`; the lifecycle ends rather than changing identity when `R <= X`.
- Slot reuse cannot inherit membership or cohort identity from an earlier task; the later pair belongs to a later cohort ID.
- Aborted and non-cohort queue leases never become cohort IDs.
- Task, slot, `stream_key`, queue-lease, cohort, and iteration identities remain distinct in control and observability records.
- Explicit independently-runnable-stream entry/exit thresholds and the `R >= E` / `R <= X` hysteresis comparators.
- An incumbent multimodal task blocks cohort entry and finishes exclusively in NORMAL.
- Multimodal tasks never contribute to `R`.
- Queued multimodal work cannot interrupt cohort phases and becomes eligible only at a decode-side `R <= X` boundary.
- INTERMISSION selects the oldest eligible multimodal task, atomically binds/clears its exact pair, rejects slot-reuse inheritance, runs only that task, holds text survivors, and grants at most one task before FORM/NORMAL resumes.
- INTERMISSION completion returns a surviving text decoder to NORMAL; direct FORM is legal only when no decoder survives and a prompt cohort can be formed.
- Multimodal helper-internal chunks/batches remain executor-owned under task-scoped authorization.
- Identical static LoRA signatures admit together without adapter switching.
- Mixed active LoRA signatures prevent cohort entry.
- Base/no-LoRA is distinct from every LoRA signature.
- Global adapter mutations wait for a cohort boundary.
- aLoRA remains NORMAL-only.
- One contiguous prompt grant per sequence per `target_manifest`.
- Prompt-member rotation.
- Reconciliation membership is committed before cache/checkpoint/spec mutation; a complete tagged reconciliation stage precedes the global fact snapshot and prompt-grant proposal.
- Parent/child atomic admission.
- Worst-case verification reservations pack within logical `n_batch`.
- Only selected reserved members enter bulk draft preparation.
- Every prepared block is scheduled in the same iteration's `target_manifest`.
- Every fresh prepared outcome remains bound to its selected stream and `iteration_id` and cannot cause reselection.
- Short actual drafts release NORMAL residual capacity only to prompt grants.
- `n_ubatch` never changes reservation or member selection.
- MTP reserves 4 rows per maximum block while ngram-mod reserves 65 under current defaults.
- Eight maximum ngram blocks reserve 520 rows and leave 32248 NORMAL prompt rows at `n_batch=32768`.
- Dynamic speculation reserves the maximum eligible implementation and reports actual shorter output.
- Capacity pressure prices asymmetric uncappable floors before max-min total-allocation water filling; exact-fit floors preserve all required participants and stable supplied order breaks ties.
- An allowed ngram cap below `n_min` falls back literally to one sampled row even when MTP or another draft family is otherwise eligible.
- Cohort formation commits exactly one homogeneous MTP-OFF or MTP-IMMEDIATE profile before cache restore/attachment.
- MTP-OFF cohorts capture no hidden rows, allocate no deferred archive, perform no activation scan, and emit no MTP verification rows.
- MTP-IMMEDIATE cohorts apply immediate MTP to every member and include its maximum in reservation from the first decode plan.
- MTP-IMMEDIATE cache tests accept only compatible restore or immediate prefill from scratch, never target-only fallback; lifetime tests select MTP-OFF when a demoting context shift can be required.
- MTP excluded for LoRA-active cohort members, including capture/backfill paths.
- Ngram speculation retained for LoRA-active cohorts.
- Incumbent MTP reaches a safe idle/demotion boundary before LoRA cohort freeze.

Server integration tests:

- One monotonic `iteration_id` correlates activation, reconciliation/preparation, the `target_batch_commit`, retry views, post-decode and complete outcome while retaining distinct command types.
- Only `target_batch_commit` or an exact scoped `external_target_commit` authorizes target execution.
- No phase, `R`, admission, barrier or next-work decision occurs after a partial batch view; every view and post action settles first.
- Outcome capture retains exact current-task identity and membership before release/reset.
- Mixed prompt/decode batches remain possible only in NORMAL.
- Cohort phases never mix prompt and decode target rows.
- No active prompt cohort starts while any attached exact stream outside its membership has decode-family pending work.
- Early prompt completion samples exactly once and does not decode before the barrier.
- NORMAL prompt completion preserves target outcome -> committed activation -> mechanical activation -> `common_speculative_begin()` -> sampling; cohort completion skips activation but begins and samples exactly once under its frozen profile.
- Speculative verification blocks remain atomic.
- Under current post-decode mechanics, batch views and retries keep the complete prepared verification prefix in the first processed view.
- Retry partition tests keep the complete verification prefix intact and split only the prompt tail.
- When effective retry capacity cannot fit the complete prefix, execution returns a typed `verification_prefix_unfit` result and takes the existing terminal cleanup/error path. It never silently slices, drops, despeculates, restores, or replans it.
- A 65-row maximum ngram block remains atomic across retry, post-decode, acceptance, rollback and replay; multi-member tests cover the stronger union-prefix rule.
- Existing replay blocks are mandatory known-size prefix work and never enter fresh bulk drafting.
- Replay tests distinguish retained-token count from total sampled-plus-replay row cost.
- `n_outputs_max`, per-sequence outputs and NextN extraction align with target-manifest membership.
- Cancellation before preparation removes the member normally; preparation commits it to the iteration.
- Partial speculative acceptance and replay remain attached to the same cohort member.
- A replay outcome coincident with `R <= X` survives the cohort-ID transition and any intermission, then runs as mandatory prefix work in the first NORMAL plan.
- Cohort prompt completion performs no deferred activation; `common_speculative_begin()` uses the already frozen immediate/OFF profile.
- An MTP-OFF member whose target context advanced through prefill or decode without matching MTP capture is not retrofitted at cohort exit.
- A no-target-work MTP-OFF survivor may be reconsidered by NORMAL, distinguishing it from target-advanced survivors.
- NORMAL deferred capture/activation behavior remains equivalent across its authority migration.
- Ngram and dynamic speculative selection and acceptance remain unchanged.
- Prompt-cache hit/miss and restore modes.
- Checkpoint restore with SWA and hybrid/recurrent memory.
- Context shift.
- Identical static LoRA cohort signatures and mixed-signature entry blocking.
- aLoRA NORMAL-only behavior.
- Parent/child `n_cmpl > 1` requests.
- Parent/child facts refresh only after successful state copying and complete `target_batch_outcome` closure.
- Cancellation in every phase.
- Cancellation while a candidate is leased or staged for admission.
- Scoped multimodal execution authorization.
- Multimodal, embedding, and rerank behavior outside text cohorts.
- Residue audit finds no scheduling use of `SLOT_STATE_*` outside the mechanical translator/outcome paths, no controller-owned member progress/debt mirror, no adapter-owned group/grant classification, and no executor work discovery.

## Production benchmark catalogue

Compare cohort-disabled NORMAL, `--no-cont-batching`, illustrative `E = 3` with both `X = 1` and `X = 2`, and at least one wider configured hysteresis pair to verify that no threshold behavior depends on those example values, using:

- The retained 8K-prefill/4K-decode workload at `b32768/u1536`.
- One active decoder plus one 128K prompt.
- One active decoder plus bursts of three, four, and eight long prompts.
- Equal-length and skewed prompt cohorts.
- Equal-length and straggler decode cohorts.
- Staggered arrivals during prefill and decode.
- Repeated crossings of configured `E` and `X`, including prompt-cohort entry and both drain-to-NORMAL exit points from the worked example.
- `n_cmpl` shared-prompt activation where `WAIT_OTHER` children become independently runnable.
- Multimodal already active at attempted entry, multimodal arriving during every cohort phase, one-task intermission ordering, multiple queued multimodal tasks and zero-work intermission.
- Cohort MTP-OFF and homogeneous MTP-IMMEDIATE profiles under the same stream shapes.
- MTP-OFF cohorts while global NORMAL deferred capture support is enabled, proving that cohort members create no hidden archive or activation work.
- NORMAL MTP active-limit/deferred cases proving behavior remains unchanged outside cohorts.
- Ngram-only, MTP-only, and dynamic mixed speculation.
- Base/no-LoRA cohorts and identical static LoRA cohorts.
- Mixed-signature arrivals held until the cohort boundary.
- aLoRA workloads remaining in NORMAL.
- LoRA cohorts with ngram speculation and MTP excluded.
- Capacity-pressure ngram caps above and below `n_min`.

Measure:

- Aggregate target tokens/s.
- Prompt tokens/s.
- Accepted decode tokens/s.
- Time to first token.
- Inter-token latency.
- Queue delay.
- Cohort makespan.
- GPU utilization.
- Cohort speculative-profile selection and MTP/ngram row composition.
- Absence of cohort MTP archive/backfill traffic in MTP-OFF mode.
- Draft acceptance.
- Trace consistency: every executed target row has one final committed work/price record; logical progress never decreases; prepared retraction and physical-position movement are reported separately; no policy refresh occurs between logical-batch views; unpaid pending debt identified by a classification trace (prompt/reconciliation, sampled-token, fresh-verification, mandatory-replay) cannot accumulate across iterations without an explicit authorization or hold record.

The following assumptions require those controlled experiments:

- Equal multi-sequence prompt distribution improves throughput on the target ROCm/hybrid configuration.
- Cohort aggregate throughput outweighs straggler delay for the intended workload.
- Homogeneous MTP-IMMEDIATE cohorts outperform MTP-OFF enough to justify retaining that optional profile.
- Static LoRA adapter application does not erase the cohort benefit.
- Per-sequence ngram draft parameters correctly honor the scheduler's fair cap and sampled-only fallback.
- One contiguous prompt grant per target manifest keeps `n_batch` sufficiently utilized.

## Open decision register

These choices remain for user review and are not implementation authorization:

1. Oversized/reduced retry capacity: RESOLVED. If the complete verification prefix cannot fit effective retry capacity, execution returns a typed `verification_prefix_unfit` result and takes the existing terminal cleanup/error path. Execution never slices, drops, despeculates, restores, or replans during this refactor. Phase 3 transfers the unfit decision from legacy authority to control, where control can later commit explicit restoration/abort and replacement work.
2. Classify each slot/cache mutation operation as immediately serviceable or boundary-gated; no generic non-inference bypass exists.
3. Incumbent embedding/rerank work: RESOLVED. Cohort mode requires a pure inference server. If the server is started with --embedding or --reranking, cohort capability is disabled at startup; the cohort phase machine never engages and embedding/rerank tasks always run in NORMAL. No drain-window or intermission policy for embedding/rerank is needed.

## Architecture review boundary

Implementation should not begin until review accepts:

1. `inference::control` as the sole scheduling-policy committer.
2. Admission and batching as proposal-only components.
3. Queue-owned cancellation-aware admission leases.
4. Server-shaped translation/execution remaining server-local.
5. The six-phase model, including pre-cohort `COHORT_ENTRY_DRAIN`, decode-boundary-only `COHORT_INTERMISSION`, and independently runnable streams as the sole threshold unit.
6. Explicit configured entry/exit thresholds and the `R >= E` / `R <= X` hysteresis comparators, with no fixed stream-count constants.
7. Dedicated monotonic per-process cohort identity atomically bound to exact `(slot, task)` membership, immutable adapter/speculative profiles, and initial prompt cursor.
8. Separation of task, slot, `stream_key`, queue-lease, cohort, and iteration identity domains.
9. Atomic admission with control-owned exact formation scope, admission-owned `formation_assessment`, and profile commit before cache restore/attachment.
10. Committed mutating preparation.
11. Contiguous per-sequence prompt grants.
12. Immutable exact adapter-signature cohorts and prompt-only rotation.
13. Immutable homogeneous cohort speculative profiles, MTP-OFF zero-work semantics, optional all-member MTP-IMMEDIATE, and LoRA-cohort MTP exclusion.
14. Exact-task-scoped exclusive multimodal authorization, opaque helper-internal batches, incumbent NORMAL blocking and one-task boundary priority.
15. Worst-case selection-before-bulk-drafting with no new prepared carry-over lifecycle, while existing replay is mandatory known-size work.
16. Participation-first ngram capping and sampled-only fallback below `n_min`.
17. The indivisible complete-verification-prefix contract, prompt-tail-only retry partitioning, and the resolved unfit outcome: a typed `verification_prefix_unfit` result on the existing terminal cleanup/error path when the prefix cannot fit effective retry capacity; execution never slices, drops, despeculates, restores, or replans.
18. The explicit operation-class table: immediate service operations, boundary-gated global model mutations, individually reviewed slot/cache mutations, and ordinary inference admission.
19. The embedding/rerank entry-boundary policy: cohort capability disabled at startup when --embedding or --reranking is enabled; the cohort phase machine never engages and embedding/rerank tasks always run in NORMAL.
20. The critical-path boundary preserving existing speculative post-processing mechanics.
21. The lifecycle-gated `(reconciled_prompt_coverage, output_committed_count)` model, with prepared extent and physical positions explicitly separate.
22. Staged prompt reconciliation: exact `prompt_reconciliation_commit`, mechanical mutation, tagged outcome, global fact snapshot, proposed grants, then `target_batch_commit`.
23. Control-owned `independently_runnable_text`, `cohort_capable`, lifecycle/task blocker classification, exact formation scope and `R`; admission-owned adapter/speculative compatibility assessment for that supplied scope; no duplicate calculation or largest-compatible-subset selection.
24. One monotonic `iteration_id` correlating distinct preparation commits and one `target_batch_commit`, with policy consuming only the complete `target_batch_outcome`.
25. The exact Phase 3 deletion boundary for categorical scheduling authority and the isolated Phase 5 NORMAL MTP-timing exception.
26. Canonical type ownership: identity/profile values, server snapshots, proposal-only admission/batching, control-only commands, and server-execution outcomes.
27. `server_context::update_slots()` as the mechanical pump with no scheduling discretion.
28. Separate compile-time dependency and runtime-flow contracts.
29. Stable cohort member order and exact prompt-cursor pruning/advancement semantics.
30. Uniform-work formation: threshold crossing is entry intent only; all exact-scope decoders drain while prompts are held; FORM binds only a decoder-free prompt-family set; only PREFILL/DECODE own `active_cohort`.
