# Cohort Progress/Debt Consolidated Architecture Delta

Status: consolidated architecture delta. It satisfies the first-pass checklist gate "Produce one consolidated architecture delta before editing either active cohort document" (COHORT_PROGRESS_DEBT_FIRST_PASS_CHECKLIST.md:104). It merges the three inputs: the first-pass findings, the authority review's conditional approval, and the current state of the two active cohort documents. It does not authorize implementation, builds, runtime tests, commits, source edits, or edits to the active cohort documents.

Inputs:
- COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md (first-pass decision, evidence, proposed deltas)
- COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md (conditional approval; six blocking corrections plus required contract corrections)
- COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md and COHORT_BATCHING_CONTROLLER_DESIGN.md (current working-tree state; the plan already contains the resolved verification-prefix decision, the Phase 5 post-decode generating-scan edits, the five audit amendments, and the working-tree reconciliation note)

Tree state verified: HEAD c448db2d6 ("server: add dormant cohort batching contracts") on branch rocm-yolo; working tree modifies both active docs and pre-lands the Phase 5 post_decode generating-scan edit in tools/server/server-context.cpp (pre_decode scan removed, post_decode scan added, capture-finalize-on-denial added) while the prompt-completion MTP call site remains live (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:9). Current working-tree call sites: post_decode generating scan at tools/server/server-context.cpp:3502-3507, prompt-completion call site at 4526-4529 (UNVERIFIED as authoritative deletion anchors; the plan's legacy anchors 3614-3618/4512-4518 refer to the pre-edit committed file).


## 2. Approved vocabulary and invariants

### 2.1 Committed logical progress tuple (lifecycle-gated names)

Committed logical progress is the ephemeral, lifecycle-gated current-task tuple:

    (reconciled_prompt_coverage, output_committed_count)

- Renamed from the first-pass "(reconciled prompt commitment, accepted output count)" (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:11-15) by the review's lifecycle-gated naming correction (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:142-150).
- econciled_prompt_coverage exists only as a tagged outcome of authorized mutating prompt reconciliation, never a passive read of slot.prompt.tokens, 
_prompt_tokens_processed, or physical KV positions (COHORT_BATCHING_CONTROLLER_DESIGN.md:356-359; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:66,90).
- output_committed_count is lifecycle-gated 
_decoded, semantically zero for WAIT_OTHER, STARTED, unreconciled/incomplete prompt, and DONE_PROMPT-before-sampling states whose reused-slot fields may be stale (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:150-161; COHORT_BATCHING_CONTROLLER_DESIGN.md:359; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:91).
- Replay material is not output-committed progress until replay succeeds and existing output processing advances 
_decoded (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:150).
- The tuple is monotonic per live {slot_id, task_id}; it never determines physical target position and never proves no target row is owed. Fully cached prompts may still owe mandatory last-token logits evaluation at tools/server/server-context.cpp:4076-4081 (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:160-162).
- Lifecycle-gate evidence: tools/server/server-context.cpp:452-492, 2251-2282, 4279-4291, 4530-4544, 4667-4686 (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:160).

### 2.2 Four distinct domains

- committed logical progress: the tuple above; monotonic for one live {slot_id, task_id}
- pending target debt: prompt/reconciliation, sampled token, fresh verification, mandatory replay
- prepared/speculative extent: may expand or retract through drafting, verification, rollback
- physical execution state: prompt representation, KV positions, checkpoints, cache, MTP archive; may restore, shift, shrink, evict, rebuild

Source: COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:17-32; mirrored in COHORT_BATCHING_CONTROLLER_DESIGN.md:11 and COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:83-93. Only the controller's global scheduling phase is persistent policy state; per-member progress/debt is rebuilt from authoritative owners each decision boundary and discarded (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:34; COHORT_BATCHING_CONTROLLER_DESIGN.md:290,1037).

### 2.3 Debt classes and pricing

| Debt | Derivation | Row pricing |
| --- | --- | --- |
| Prompt/reconciliation | Runnable text member has unsatisfied prompt coverage or mandatory logits-producing prompt reconciliation | Contiguous prepared legal grant |
| Sampled token | Accepted sampled token still owes target evaluation; no prepared block supersedes it | One ordinary row, or worst-case speculative reservation envelope before drafting |
| Fresh verification | Selected fresh drafting produced a sampled-plus-proposal block | Exact actual atomic block |
| Mandatory replay | Existing runtime reports spec_is_replay and retained accepted replay material | Known actual atomic block, priced before fresh candidates |
| No runnable target debt | No authorized target work currently owed | Zero |

Source: COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:90-100; mirrored COHORT_BATCHING_CONTROLLER_DESIGN.md:361-368. Precedence prevents double pricing: mandatory replay supersedes standalone sampled/fresh classification; prepared fresh verification supersedes standalone sampled-token debt; sampled-token debt flows worst-case reservation -> control-selected fresh set -> bulk draft selected set only -> refreshed projection reports exact verification debt (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:102-116).

### 2.4 R and eligibility facts

R = count(independently_runnable_text && cohort_capable) (COHORT_BATCHING_CONTROLLER_DESIGN.md:807-815,824; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:188-191). It is control-derived over the complete passive snapshot, never a largest compatible adapter subset (COHORT_BATCHING_CONTROLLER_DESIGN.md:813).

- server_inference reports raw facts only: exact current {slot_id, task_id}, attachment/liveness, mechanically interpreted lifecycle state, task kind, dependency identity/satisfaction, adapter/aLoRA facts, speculative runtime capability/synchronization facts (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:76-83).
- inference::control applies the eligible-stream predicate and derives R. A mechanical fact may be named dependency_satisfied; it must not silently mean cohort eligibility (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:84).
- Classifications are control-only: independently_runnable_text, cohort_capable, cohort_blocker, exact formation scope, lifecycle/task blockers (COHORT_BATCHING_CONTROLLER_DESIGN.md:807-815). inference::admission alone computes the exact-scope adapter/speculative ormation_assessment; control commits or rejects without recalculating (COHORT_BATCHING_CONTROLLER_DESIGN.md:515,539-540).
- WAIT_OTHER exposes dependency identity but no independently runnable target debt; after parent state copying, refreshed facts expose each activated child (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:88; tools/server/server-context.cpp:4434-4453).
- Evidence for raw-fact-only reporting: slot liveness tools/server/server-context.cpp:560-562; WAIT_OTHER attachment 2239-2246; parent-copy activation 4434-4453 (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:86-91).

### 2.5 Term split: pending debt / priced proposal / authorized work

    pending work/debt   = phase-neutral derivation from owner facts
    priced proposal     = batching-selected reservation/block/grant proposal
    authorized work     = control-committed action or final target batch only

Source: COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:164-177; mirrored COHORT_BATCHING_CONTROLLER_DESIGN.md:370,590-592 and COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:71,95. "No pending target debt" cannot mean "not authorized in this phase": INTERMISSION and cohort barriers preserve visible debt while withholding authorization (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:179).

### 2.6 Prepared verification as a tagged preparation outcome

Fresh drafting mutates speculative/runtime state; its exact block identity and actual rows return as a preparation outcome bound to the already selected member and iteration lineage, never re-entering the general candidate-fact path (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:181-184). The opaque descriptor is equivalent to the existing prepared_decode_block contract: block identity, exact owner, fresh-or-replay origin, actual atomic target rows (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:185-193; COHORT_BATCHING_CONTROLLER_DESIGN.md:440-447). Batching packs descriptors; it does not scan spec_draft, spec_i_batch, checkpoint, or implementation internals (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:194).

### 2.7 Exact replay row meaning

On checkpoint replay, spec_draft contains retained accepted replay tokens and spec_is_replay owns the classification at tools/server/server-context.cpp:4612-4631 (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:196-198). The next target block contains one sampled base row plus retained replay tokens (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:200-204). If a fact reports retained tokens, name it eplay_token_count and price 1 + replay_token_count; if it reports total block rows, name it eplay_rows. Never maintain either in control (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:206; COHORT_BATCHING_CONTROLLER_DESIGN.md:488,974).

### 2.8 Runtime speculative facts vs cohort policy

Do not overload one speculative_eligible_mask (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:208-217; COHORT_BATCHING_CONTROLLER_DESIGN.md:519):
- runtime/capability mask: existing speculative owner
- stateful synchronized mask: existing speculative owner
- immutable cohort allowed profile: inference::control
- effective reservation input: explicit result after committed activation/profile application

An MTP-OFF cohort never regains MTP merely because runtime eligibility reports it (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:217; COHORT_BATCHING_CONTROLLER_DESIGN.md:519,682,966).

### 2.9 Phase 5 prompt-completion ordering

Generating-scan path: facts -> control activation commit -> mechanical attempt -> refreshed runtime masks/maxima -> debt pricing/reservation. Prompt-completion path: prompt target outcome -> control activation commit -> mechanical activation -> common_speculative_begin() exactly once -> sampling/client outcome -> quiescent progress refresh -> next iteration lineage. Debt never decides MTP eligibility or activation timing (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:219-243; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:724-742; COHORT_BATCHING_CONTROLLER_DESIGN.md:627,919-943).

### 2.10 Phase 4 wording

The progress/debt delta adds no new admission authority; Phase 4's existing accepted-set/window transfer is unchanged. Parent/child activation is an execution outcome after mechanical state copying, not admission; its facts refresh only at complete-manifest closure (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:245-249; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:628,672).

### 2.11 Phase 0 evidence honesty

Phase 0 captures source-annotated fixtures and currently observable manifests/outcomes only. Live shadow projection of transient reconciled facts begins with the Phase 2 translator unless Phase 0 explicitly authorizes behavior-neutral diagnostic instrumentation (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:251-253; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:384-386).


## 3. Blocking-correction resolutions

### 3.1 Reconciliation is authorized mutating preparation, not passive projection

Correction: local 
_past is produced while STARTED processing mutates prompt/cache/checkpoint/speculative/memory state (tools/server/server-context.cpp:3786-4125), including target-memory truncation (4138-4143) and immediate prompt-row preparation (4210-4235); the first pass mispresented it as passive projection (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:26-32).

Resulting contract (staged; no target work, admission sweep, phase transition, fairness advancement, or unrelated scheduling decision between stages):

    passive raw slot/task/capability facts
        -> batching proposes exact members requiring reconciliation
        -> control commits prompt-reconciliation membership
        -> server_execution and existing owners reconcile mechanically
        -> tagged reconciled-prompt outcomes are published
        -> server_inference builds one global ephemeral fact snapshot
        -> batching proposes exact prompt grants
        -> control commits the final target batch

Source: COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:34-47. server_inference may translate passive facts; it must not perform or conceal reconciliation. An unreconciled member cannot satisfy the zero-prompt-debt cohort barrier (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:49). The active docs already embed the staged contract: COHORT_BATCHING_CONTROLLER_DESIGN.md:631-633, COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:513,581-582,809.

### 3.2 One iteration lineage contains several controller commits

Correction: "one committed manifest" collapses distinct authorization stages; exact rows and prompt grants are not all knowable before reconciliation and drafting (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:51-53).

Resulting contract:

    iteration lineage
        committed activation action, when applicable
        committed decode-preparation action
        committed prompt-reconciliation/preparation action
        tagged preparation outcomes
        final committed target batch
        mechanical retry views
        complete execution outcome

Source: COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:55-66. Only the final committed target batch authorizes target execution; execution may assign offsets mechanically but may not select membership, distribute residual capacity, or finalize policy (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:68). The lineage needs an immutable handle/reference passed through preparation, retry, post-decode, and outcome reporting; it need not be a new persistent controller lifecycle or process-global monotonic ID (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:70). Active-doc mapping: iteration_id is monotonic per process (COHORT_BATCHING_CONTROLLER_DESIGN.md:589,623-637; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:67,319); invariant 48 "one iteration_id may correlate several committed preparation actions, only its target_batch_commit authorizes target execution" (COHORT_BATCHING_CONTROLLER_DESIGN.md:1042); lineage handle is not implementation vocabulary (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:331).

### 3.3 Control derives R; the adapter reports raw dependency/task facts

Correction: no source-owned "eligible independently runnable cohort stream" boolean exists; it combines mechanical and policy semantics (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:72-74). The first-pass facts struct's independently_runnable and single speculative_eligible_mask are superseded (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:56-76 vs COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:76-84,208-217).

Resulting contract: server_inference reports exact liveness/lifecycle/task-kind/dependency/adapter-aLoRA/speculative-capability facts; inference::control applies the approved eligible-stream predicate and derives R; a mechanical fact never silently means cohort eligibility (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:76-84). Admission computes the exact-scope formation assessment; control commits or rejects (COHORT_BATCHING_CONTROLLER_DESIGN.md:813-815,1040). Raw facts must contain no pre-decided runnable/capable/blocker verdict or R (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:447,614; COHORT_BATCHING_CONTROLLER_DESIGN.md:351).

### 3.4 Policy consumes outcomes only after the complete logical manifest closes

Correction: the server may process one logical batch through several atch_views with post-decode after each (tools/server/server-context.cpp:3460-3499); per-view results may be accumulated mechanically, but no global refresh, barrier advance, R derivation, admission, or next-iteration planning may consume a partial view (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:93-101).

Resulting contract: policy consumes only iteration_completion; target iterations require the complete 	arget_batch_outcome after every view executes and post-processing settles, or one explicit terminal failure outcome (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:69; COHORT_BATCHING_CONTROLLER_DESIGN.md:625,636-637,1044). This preserves the whole-verification-prefix limitation and introduces no manifest-view-aware speculative processing (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:102). The outcome snapshot retains exact manifest membership and {slot_id, task_id} before release clears current-task state at tools/server/server-context.cpp:678-705 (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:104).

### 3.5 Phase 3 enumerates the exact legacy authority deletion catalogue

Correction: the first pass listed deletion only abstractly (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:181,189). Phase 3 must catalogue exact legacy authority (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:106-122):

| Legacy categorical scheduling authority | Source (committed pre-edit anchor) | Disposition |
| --- | --- | --- |
| Generating selection and speculative preparation | tools/server/server-context.cpp:3629-3745 | Deleted at Phase 3 takeover |
| Prompt membership, compatibility, reconciliation, grants | tools/server/server-context.cpp:3754-4292 | Deleted at Phase 3 takeover |
| Context-shift maintenance selected from generating state | tools/server/server-context.cpp:3546-3612 | Deleted at Phase 3 takeover |
| Independent MTP activation, pre_decode maintenance pass | tools/server/server-context.cpp:3614-3618 | Temporary exception until Phase 5 |
| Independent MTP activation, post_decode prompt-completion transition | tools/server/server-context.cpp:4512-4518 | Temporary exception until Phase 5 |

Scheduling uses of SLOT_STATE_* are deleted at takeover; mechanical lifecycle/response uses are retained in server_inference and post-decode mechanics; controller-authorized context-shift/reconciliation maintenance replaces the deleted paths; the sole temporary exception is isolated legacy NORMAL MTP activation timing removed atomically in Phase 5 (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:115-120). After Phase 3, no path outside the mechanical fact translator/outcome mechanics may derive target membership, grants, preparation, or maintenance authorization from categorical slot state (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:122). The plan already enumerates the deletion and the temporary exception (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:586-590,604-605) and deletes both activation sites in Phase 5 (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:709,717,746).

### 3.6 Oversized verification-prefix failure: RESOLVED

Correction: the review listed this as an open authority decision (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:124-138), but the owner has resolved it and the active docs now carry the resolution (COHORT_BATCHING_CONTROLLER_DESIGN.md:1316,1340; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:274). This delta incorporates it as resolved, not open.

Resulting contract: if the complete verification prefix cannot fit effective retry capacity, execution returns a typed erification_prefix_unfit result and takes the existing terminal cleanup/error path; execution never slices, drops, despeculates, restores, or replans. Phase 3 transfers the unfit decision from legacy authority to control, where control can later commit explicit restoration/abort and replacement work (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:274; COHORT_BATCHING_CONTROLLER_DESIGN.md:645,1316). Prompt-tail-only retry partitioning and the indivisible complete-verification-prefix contract remain (COHORT_BATCHING_CONTROLLER_DESIGN.md:643-645,1001,1340; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:286-290).


## 4. Authority matrix (final form)

Incorporates the review's corrected matrix (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:255-269) reconciled with the current component-authority table (COHORT_BATCHING_CONTROLLER_DESIGN.md:202-216) and the plan's single-producer list (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:78).

| Concern | Authority |
| --- | --- |
| Raw slot/task lifecycle and current task state | Existing slot/task owner |
| Cache/checkpoint/speculative reconciliation mechanics | Existing owners under control-committed member scope |
| Reconciled-prompt outcome | Mechanical execution result (`server_execution`), exact-member and lineage tagged |
| Raw fact translation | `server_inference`, passive and history-free |
| Eligible-stream predicate and `R` | `inference::control` |
| Pending debt derivation and row/grant pricing | `inference::batching`, proposal only |
| Activation, preparation, phase and final target authorization | `inference::control` |
| Draft/replay/checkpoint lifecycle | Existing speculative runtime and slot |
| Target execution and retry-view construction | `server_execution`, mechanical under the committed batch |
| Complete outcome publication | `server_execution`, lineage-tagged after all views settle |
| Next phase/admission/work decision | `inference::control` |
| Exact-scope adapter/speculative `formation_assessment` | `inference::admission`, proposal only; control commits or rejects |
| Queue contents/order/cancellation visibility/leases | Existing `server_queue` type |
| Placement plan + mechanical attachment transaction | `server_inference::admission_adapter`, plans once and applies the same committed plan once |
| Passive lifecycle-gated progress projection | `server_inference::snapshot_reader` |
| Global phase machine, membership, cohort/iteration identity, barriers, cursor | `inference::control` |

No proposal authorizes work; the authority chain is raw facts -> proposal -> control commit -> mechanical mutation/execution -> tagged outcome -> refreshed facts at a quiescent boundary (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:11-22; COHORT_BATCHING_CONTROLLER_DESIGN.md:81-93; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:25-34). No adapter, executor, cache owner, speculative runtime, or batching component may fill an omitted policy decision (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:22).

## 5. Phased-plan delta (Phases 0-8)

Status facts: Phase 1 is committed as c448db2d6; the working tree pre-lands the Phase 5 post-decode generating-scan edit; the second legacy MTP call site remains live; Phase 2 has not started (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:9). The progress/debt delta's integration in Phases 4 and 7 is terminology/telemetry only, confirmed by source evidence: Phase 4's existing accepted-set/window admission transfer is unchanged by the delta (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:245-249; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:628), and Phase 7 is configuration/telemetry/residue-check with no authority transfer (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:895-897,891-985).

| Phase | Delta | Evidence |
| --- | --- | --- |
| 0 | Capture source-annotated fixtures and currently observable manifests/outcomes only; no live shadow projection of transient reconciled facts; annotate lifecycle-gated vs prepared/retractable vs physical fields | COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:384-432; COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:251-253 |
| 1 | COMMITTED (c448db2d6): dormant vocabulary and leaf-pure proposals; store no progress/debt state in control | COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:434-487 |
| 2 | Extract one mechanical `server_inference` translator under the legacy manifest producer; preserve one iteration lineage through execution/outcome; compare but never apply projected debt; staged reconciliation seam | COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:489-558; COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:189 |
| 3 | NORMAL consumes the projection and derives/prioritizes debt; delete the exact legacy categorical catalogue (server-context.cpp:3629-3745, 3754-4292, 3546-3612) atomically; isolate legacy MTP timing exception; transfer `verification_prefix_unfit` decision to control | COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:560-618; COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:106-122; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:274 |
| 4 | Terminology/telemetry only for progress/debt: refresh facts across attachment/cancellation/release/slot reuse and parent/child activation at complete-manifest closure; admission authority unchanged | COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:191; COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:245-249; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:628,671-672 |
| 5 | Enforce activation commit -> mechanical outcome -> refreshed speculative/progress facts -> repriced debt -> target manifest; delete both independent legacy activation decisions atomically; explicit generating-scan and prompt-completion orderings | COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:192; COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:219-243; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:697-769 |
| 6 | Replace categorical cohort predicates with prompt/decode/replay debt predicates while retaining all six global phases and E/X hysteresis | COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:193; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:771-889 |
| 7 | Terminology/telemetry only: progress/debt telemetry and residue checks; configuration and authority unchanged | COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:194; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:891-985 |
| 8 | Add projection, frontier, classification, manifest-continuity, cache/context/replay and authority-deletion regressions plus trace-consistent ROCm validation | COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:195; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:987-1043 |

The server/non-server split remains unchanged; projection, debt derivation, and controller policy are server-local; common speculative, sampling, cache/checkpoint, model, and backend mechanics remain unchanged (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:197; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:304-311). No phase renumbering, authority redesign, workstream change, or deferred-scope expansion (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:262).

## 6. Controller-design rewrite catalogue

Section-by-section edits `COHORT_BATCHING_CONTROLLER_DESIGN.md` will need; line numbers are the current working-tree state.

| Section | Lines | Required edit |
| --- | --- | --- |
| Objective | 7-25 | Reference lifecycle-gated tuple and four domains (already partially present at 11); state no persistent computed frontier |
| Existing authority map | 27-75 | Extend the current batch scheduling entry (71) and pre_decode/post_decode entries with the exact Phase 3 legacy deletion catalogue ranges and the two temporary MTP exceptions |
| Authority boundary | 77-121 | Add staged exact-stream prompt reconciliation and one-iteration-lineage-with-several-commits to the control-commits list; add the review's authority chain wording; control does not own per-member mirrors (already at 121) |
| Namespace and dependency boundary | 123-245 | Confirm `prompt_reconciliation_outcome` / `prepared_decode_outcome` lineage tags and opaque descriptor fields (already at 432-453); keep Phase 1 surface statement (198) unchanged |
| Persistent state | 247-323 | Re-verify control_state's no-mirror list (290) against the review's matrix; no new persistent computed frontier; iteration lineage needs only a handle, not a persistent global ID |
| Facts and proposals | 347-528 | Confirm raw-facts-only `stream_snapshot` (395-399); split speculative masks (519); rename replay field per 2.7; `pending_work` as derived debt (456-461); fresh descriptors never re-enter candidate discovery (488) |
| Admission contract | 530-563 | Unchanged in substance; confirm no progress/debt projection is stored at admission time (Plan:628) |
| Slot release contract | 565-581 | Unchanged; release reports freed capacity and snapshot omission (567-576) |
| Canonical scheduling vocabulary | 583-603 | Add `reconciled_prompt_coverage` / `output_committed_count` and the pending-debt/priced-proposal/authorized-work split (370 already present) |
| Mechanical dispatch point | 605-619 | Confirm `update_slots()` is the sole `iteration_completion` assembler (already 607-619); add complete-manifest closure gate |
| Iteration-planning contract | 621-645 | Insert the staged reconciliation contract (3.1) as explicit steps; retain the 13-step lineage (625-637); incorporate `verification_prefix_unfit` as resolved (645 already) |
| Speculative row accounting and lifecycle | 647-731 | Rename replay facts per 2.7; state runtime masks vs cohort profile vs effective reservation input (already 519) |
| Target-row rules | 733-746 | Unchanged by the delta |
| Immutable cohort adapter and speculative profiles | 748-777 | Unchanged; MTP-OFF never regains MTP |
| Prompt-grant algorithm | 779-803 | Ensure grants come only after one global post-reconciliation snapshot (already implied by 785) |
| Stream-count and hysteresis contract | 805-841 | Confirm control derives `R`; adapters report raw facts (already 815) |
| Pre-cohort drain and uniform-work formation contract | 843-872 | Unchanged in substance |
| Multimodal boundary contract | 874-888 | Unchanged in substance |
| Phase-transition table | 890-917 | Replace any residual `SLOT_STATE_*` predicate phrasing with debt predicates; PREFILL barrier closes on zero prompt/reconciliation debt |
| Early prompt completion | 919-947 | Adopt the 2.9 prompt-completion ordering and lifecycle-gated tuple |
| Cohort speculative-profile contract | 949-966 | Update the two legacy call-site line anchors to the Phase 5 post-decode scan wording (962 already states deletion) |
| Replay and checkpoints | 968-976 | Apply exact replay row meaning (2.7) and mandatory-prefix-first pricing |
| Non-cohort work | 978-991 | Unchanged |
| Required invariants | 993-1058 | Add/confirm invariants 43-54 (progress tuple, staged reconciliation, raw facts only, iteration lineage, complete-manifest closure, distinct masks, unfit outcome) |
| Critical-path change boundary | 1060-1093 | Replace the generic deletion bullet (1071) with the exact catalogue from 3.5 |
| Configuration | 1095-1109 | Unchanged |
| Observability | 1111-1141 | Add reconciled-coverage/output-committed/pending-debt per member, refresh cause, prepared retraction, and keep identities out of Prometheus labels (already at 1122-1134, 1141) |
| Implementation decomposition | 1143-1153 | Unchanged |
| Regression catalogue | 1155-1263 | Add lifecycle-gated stale-field regressions, debt-derivation regressions, lineage-continuity, unfit outcome, and post-Phase 3/5 deletion residue audits (already partially at 1160, 1227-1230, 1263) |
| Production benchmark catalogue | 1265-1310 | Add trace-consistency debt checks (already 1301) |
| Open decision register | 1312-1318 | Mark decision 1 RESOLVED (already 1316); retain decisions 2 and 3 as open |
| Architecture review boundary | 1320-1353 | Items 21-25 already carry the progress/debt contracts; no new items required beyond aligning wording with this delta |


## 7. Phased-plan rewrite catalogue

Section-by-section edits `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md` will need; line numbers are current working-tree state.

| Section | Lines | Required edit |
| --- | --- | --- |
| Working-tree reconciliation note | 9-10 | Already present and accurate; no change |
| Accepted structural direction | 11-51 | No structural changes |
| Corrections incorporated | 52-78 | Already includes all 23 corrections; no new correction needed |
| Accepted progress/pending-work model | 80-95 | Already reflects the corrected tuple, lifecycle gates, four domains, and term split; tighten to match the consolidated vocabulary names (2.1-2.5) |
| Accepted adapter and speculation scope | 99-118 | Unchanged |
| Accepted cohort identity model | 120-182 | Unchanged |
| Accepted stream threshold and exit policy | 184-202 | Already carries control-derived `R` from passive facts; confirm wording |
| Accepted multimodal intermission policy | 204-218 | Unchanged |
| Accepted speculative-preparation policy | 220-268 | Unchanged; capacity-pressure ngram policy remains |
| Decisions still requiring consultation | 270-277 | Already carries the resolved verification-prefix decision (274) and open decisions 2-3 (275-276); no change |
| Initial refactor scope boundary | 280-290 | Already carries resolved `verification_prefix_unfit` (290); no change |
| Phase 0 | 376-432 | Add: Phase 0 captures source-annotated fixtures and currently observable manifests/outcomes only; live shadow projection of transient reconciled `n_past` begins Phase 2 unless Phase 0 explicitly authorizes diagnostic instrumentation (per 2.11) |
| Phase 1 | 434-487 | Already committed; note that the exact-stream `prompt_reconciliation_result` vocabulary (Plan:448) exists but full iteration-tagged `prompt_reconciliation_outcome` types begin Phase 2 |
| Phase 2 | 489-558 | Add staged reconciliation seam contract (3.1); add `verification_prefix_unfit` outcome implementation; confirm the non-applying comparator is shadow evidence only |
| Phase 3 | 560-618 | Replace the abstract "legacy slot-state-to-membership/grant interpretation" deletion (Plan:587-589) with the exact legacy catalogue from 3.5; add post-Phase 3 verification gate commands (Plan:604-605 already present, expand) |
| Phase 4 | 620-695 | Add: parent/child activation is execution outcome, not admission decision; facts refreshed only at complete-manifest closure (per 2.10) |
| Phase 5 | 697-769 | Add generating-scan vs prompt-completion ordering (2.9); note pre-landed post_decode edit must be re-verified; specify both legacy call-site deletions in the deletion catalogue (Plan:746 already present) |
| Phase 6 | 771-889 | Replace any residual `SLOT_STATE_*` predicate wording with `prompt_family_pending`/`decode_family_pending` (already defined in Plan:791 and Design:849-856) |
| Phase 7 | 891-985 | Add verification that Phase 3 deleted the catalogued legacy ranges; add Phase 5 deletion verification commands |
| Phase 8 | 987-1043 | Add lifecycle-gated stale-field, reconciliation-staging, `verification_prefix_unfit` path, and replay-pricing regression tests |
| Authority by phase table | 1045-1056 | Ensure Phase 3 row says "legacy planner deleted" and Phase 5 row says "both legacy activation sites deleted" (already Plan:1051,1053) |
| Final approval boundary | 1061-1090 | Verify items 18-25 already carry the progress/debt contracts; no new items beyond alignment |


## 8. Validation and observability deltas

### 8.1 CPU/fixture validation

Required list from the first pass stands and is incorporated (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:199-214):

- Ordinary and fully cached prompts, including forced last-token logits evaluation.
- Early prompt completion and exactly-once sampled debt.
- Fresh MTP/ngram preparation, full/partial acceptance, prepared-edge retraction.
- Checkpoint restoration and replay creation/consumption.
- Context shift: committed output progress monotonic while physical extent moves.
- `WAIT_OTHER` before parent copy and independent children after activation.
- Cancellation before/after preparation, release, slot reuse under a different task ID.
- Replay across cohort exit and multimodal intermission.
- MTP-OFF target-advanced survivors and LoRA MTP-OFF with ngram debt.
- One iteration lineage through preparation, retry views, target execution, post-decode, outcome.
- Absence of controller-owned copied prompt, sampled, replay, checkpoint, cache, speculative, or frontier state.
- Absence of any legacy categorical scheduling interpretation after Phase 3.

The active docs carry these plus progress-specific regressions: lifecycle-gated stale-field exclusion, reconciliation staging, lineage continuity, unfit outcome, and replay pricing (COHORT_BATCHING_CONTROLLER_DESIGN.md:1155-1263; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:997-1009). No additions required beyond the resolved unfit outcome and the exact replay-pricing distinction (2.7).

### 8.2 Controlled validation

Required list from the first pass stands (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:216-222):

- SWA/hybrid/recurrent checkpoint coverage: current source records inaccurate inferred checkpoint coverage for SWA at tools/server/server-context.cpp:2791-2794 (verified: TODO at 2792-2794).
- Cache reuse plus forced last-token evaluation at tools/server/server-context.cpp:4076-4091 (verified: 4086-4089).
- Context shift with monotonic accepted-output count and shrinking physical extent.
- Parent/child activation and runnable-stream recount.
- Fault-injected decode retry proving projections are published only at quiescent boundaries, never while prepared rows are uncommitted.

The plan additionally requires the Phase 5 pre-landed scan be re-verified against the final Phase 5 design (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:9).

### 8.3 Prometheus low-cardinality metrics

Aggregate, low-cardinality only (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:236; COHORT_BATCHING_CONTROLLER_DESIGN.md:1141; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:969):

- debt/rows by phase/class
- reserved-versus-actual rows
- held/blocked counts
- committed advances
- prepared retractions
- refresh causes
- manifest/outcome mismatch count

Task, slot, lease, cohort, and manifest identities remain structured-log/debug-only (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:236; COHORT_BATCHING_CONTROLLER_DESIGN.md:1141). Structured per-manifest diagnostics (findings list at COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:226-234) remain: global phase and exact identity, reconciled coverage/output-committed, pending sampled debt, prepared/replay extent, derived debt set, reservation/actual cost with authorization/hold reason, outcome advancement, prepared retraction, replay creation/consumption, completion/cancellation/release, refresh cause, and physical positions marked diagnostic/non-semantic.

## 9. Deferred boundary

The new seam enables but does not absorb (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:238-247):

- Manifest-view-aware speculative processing.
- Paged target-KV work.
- Prompt-checkpoint DRAM-copy optimization.
- Dynamic mid-decode MTP reconstruction.

All remain in `deferred-todo-work.md`. The active refactor preserves the complete verification-prefix limitation and existing cache/speculative/model/backend mechanics (COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:247). None of these enter any phase of the active plan (COHORT_PROGRESS_DEBT_AUTHORITY_REVIEW.md:277-284).

## 10. Open items remaining after this delta

- Consultation decision 2: classify each slot/cache mutation operation as immediately serviceable or boundary-gated; no generic non-inference bypass exists (COHORT_BATCHING_CONTROLLER_DESIGN.md:1317; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:275). No resolution is invented here.
- Consultation decision 3: decide whether incumbent embedding/rerank work finishes in NORMAL before entry or remains a cohort blocker until it clears (COHORT_BATCHING_CONTROLLER_DESIGN.md:1318; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:276). No resolution is invented here.

Other genuinely unresolved items found during this pass: none beyond the above. The verification-prefix capacity decision is resolved (COHORT_BATCHING_CONTROLLER_DESIGN.md:1316; COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:274). The one UNVERIFIED item is the current working-tree call-site line numbers for the legacy MTP activation paths (post-decode scan at tools/server/server-context.cpp:3502-3507, prompt-completion call site at 4526-4529); the plan's authoritative anchors remain the committed pre-edit ranges 3614-3618 and 4512-4518 (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:709,746). The architecture review's six blocking corrections are all resolved above in section 3; nothing remains open from that review.

## 11. Authorization statement

This delta does not authorize implementation. It awaits owner approval before the active-document rewrites of `COHORT_BATCHING_CONTROLLER_DESIGN.md` and `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md` (COHORT_PROGRESS_DEBT_FIRST_PASS_CHECKLIST.md:104-106; COHORT_PROGRESS_DEBT_FIRST_PASS_FINDINGS.md:3). No source, test, or other file edits, builds, commits, or runtime tests are authorized by this document.


