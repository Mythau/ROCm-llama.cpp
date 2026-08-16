# Cohort Decision 3 Findings: Embedding/Rerank Entry Boundary Policy

Working tree: `2026-08-12/source/llamacpp-yolo-allpatches-gfx1100-gfx1201` (branch `rocm-yolo`, HEAD c448db2d6).
Register item: `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:276` — "Incumbent embedding/rerank work: finish in NORMAL or remain a cohort blocker until it clears."
All line numbers verified against HEAD.

## A. Source Map: Embedding/Rerank Execution Path

### Admission

- HTTP entry creates one `server_task` per input and queues it:
  - Rerank: one task per document, `format_prompt_rerank(...)` then `server_task(SERVER_TASK_TYPE_RERANK)`, `rd.post_tasks(...)` — `tools/server/server-context.cpp:5811-5820`.
  - Embedding: one task per tokenized prompt, `server_task(SERVER_TASK_TYPE_EMBEDDING)` with `params.res_type`/`params.embd_normalize`, `rd.post_tasks(...)` — `tools/server/server-context.cpp:6093-6107`.
- Queue pump dispatches each task to `process_single_task()` — `tools/server/server-context.cpp:1757,2817`. `SERVER_TASK_TYPE_EMBEDDING` and `SERVER_TASK_TYPE_RERANK` fall into the shared inference branch — `tools/server/server-context.cpp:2821-2822`.
- CLI input is tokenized inside that branch; HTTP tasks arrive pre-tokenized — `tools/server/server-context.cpp:2826-2830`.
- `select_slots(task)` is called — `tools/server/server-context.cpp:2834`. On `SLOT_SELECTION_NO_SLOT`, `SLOT_SELECTION_SLOT_UNAVAILABLE`, or `SLOT_SELECTION_GROUP_UNAVAILABLE` the task is deferred back to `queue_tasks` — `tools/server/server-context.cpp:2840-2858`. There is no task-kind-specific reservation in `select_slots`; embedding/rerank compete with text tasks for ordinary idle slots.

### Slot assignment

- `prepare_slot_launch(...)` binds task to slot — `tools/server/server-context.cpp:2142,2870-2871`.
- Sampler is initialized only when `task.need_sampling()` — `tools/server/server-context.cpp:2208-2221`; embedding/rerank return `false` from `need_sampling()` — `tools/server/server-context.h` (`server-task.h`) `need_sampling()` — `server-task.h:211-217`, so no sampler chain is built for them.
- Speculative policy occupancy is planned for the newly prepared slots — `tools/server/server-context.cpp:2876-2894`. Under deferred MTP, tasks where `!prepared[i].task->need_sampling()` have their MTP bit cleared from `policy.incoming_masks` — `tools/server/server-context.cpp:2895-2904`. Embedding/rerank are therefore MTP-excluded at admission when `spec_mtp_deferred` is on (they are also excluded from drafting at batch time, below).

### Task-kind flags

- `server_task_type` enum: `SERVER_TASK_TYPE_EMBEDDING` and `SERVER_TASK_TYPE_RERANK` are distinct kinds — `tools/server/server-task.h:20-23`.
- `need_embd()` returns `true` for EMBEDDING and RERANK only — `tools/server/server-task.h:191-199`.
- `need_logits()` and `need_sampling()` return `true` for COMPLETION and INFILL only — `tools/server/server-task.h:203-217`.
- There is no task-level "exclusive" flag in `server-task.h` or `server-common.h`; exclusivity is emergent from task type + slot batching predicates, not declared.

### Batch building (pre_decode)

- `server_slot::need_embd()` = `task->need_embd() || (spec && common_speculative_need_embd(spec))` — `tools/server/server-context.cpp:518-521`.
- Prompt rows are added with `output = slot.need_embd()`; the comment states "embedding requires all tokens in the batch to be output" — `tools/server/server-context.cpp:4238-4244`.
- **Embeddings-mode enable:** just before decode, `llama_set_embeddings(ctx_tgt, slot_batched->need_embd())` is applied per batch, keyed off the *first batched slot only* — `tools/server/server-context.cpp:3446-3458`.
- `can_batch_with(other)` requires identical `task->type`, identical `inp_embd.size()`, and equal LoRA — `tools/server/server-context.cpp:534-539`. Consequence: a `SERVER_TASK_TYPE_EMBEDDING` slot can batch only with other `SERVER_TASK_TYPE_EMBEDDING` slots, a `SERVER_TASK_TYPE_RERANK` slot only with rerank slots, and neither can batch with COMPLETION/INFILL generation slots. The batching predicate is enforced at batch population for generating slots — `tools/server/server-context.cpp:3644-3650` — and for prompt slots — `tools/server/server-context.cpp:3775-3781`.
- `can_split()` forbids splitting embeddings work across ubatches unless a memory module exists and pooling is `LLAMA_POOLING_TYPE_LAST` — `tools/server/server-context.cpp:524-532`; the guard errors out over-large single-ubatch prompts — `tools/server/server-context.cpp:3850-3863` — and holds batch fill when the whole prompt does not fit — `tools/server/server-context.cpp:4139-4142`.

### Decode

- `decode(...)` calls `llama_decode(ctx_tgt, batch_view)` — `tools/server/server-context.cpp:4378`.
- If speculation is loaded and the batch has embeddings, an `inp_embd`-width mismatch between draft and target models throws `"unsupported batch.has_embd + spec case"` — `tools/server/server-context.cpp:4362-4368`. (That branch is for embedding-vector-input batches, not embedding-output batches, but it is the only explicit spec+embd guard in decode.)
- MTP nextn embeddings are toggled per batch via `llama_set_embeddings_nextn(ctx_tgt, need_embd_nextn, false)` — `tools/server/server-context.cpp:4371-4374`; `common_speculative_need_embd_nextn` returns `false` whenever `batch_in.token == nullptr || batch_in.embd != nullptr` — `common/speculative.cpp:2114-2118` (MTP) and `common/speculative.cpp:958-965` (draft-MLP family), so embedding-vector-input batches disable MTP nextn capture. For token-input batches (all embedding/rerank HTTP requests here), MTP nextn stays eligible-flag-driven.

### Slot state transition

- When the whole prompt is consumed: `slot.state = SLOT_STATE_DONE_PROMPT`, last batch row flagged as output, `slot.i_batch` recorded — `tools/server/server-context.cpp:4288-4297`.
- Parent/child state copy applies only to `n_cmpl > 1` parents — `tools/server/server-context.cpp:4448-4466`.

### post_decode → result → release

- On `SLOT_STATE_DONE_PROMPT`:
  - `SERVER_TASK_TYPE_EMBEDDING` → `send_embedding(slot, batch_view); slot.release(); slot.i_batch = -1; return;` — `tools/server/server-context.cpp:4506-4514`.
  - `SERVER_TASK_TYPE_RERANK` → `send_rerank(slot, batch_view); slot.release(); slot.i_batch = -1; return;` — `tools/server/server-context.cpp:4515-4521`.
  - Otherwise `GGML_ASSERT(slot.task->need_sampling())` and the slot enters `SLOT_STATE_GENERATING` with speculative begin — `tools/server/server-context.cpp:4523-4530`.
- `send_embedding` pulls `llama_get_embeddings_ith` (pooling NONE) or `llama_get_embeddings_seq` (pooled) per batch row and normalizes when pooling exists — `tools/server/server-context.cpp:2621-2660`.
- `send_rerank` reads `llama_get_embeddings_seq(ctx_tgt, seq_id)` falling back to `llama_get_embeddings_ith`, takes `embd[0]` as the score — `tools/server/server-context.cpp:2666-2690`.
- `release()` returns the slot to `SLOT_STATE_IDLE` and aborts an active speculative cycle — `tools/server/server-context.cpp:678-699`.

### Duration/lifecycle evidence (short-lived, no decode iteration)

- Embedding/rerank tasks never transition to `SLOT_STATE_GENERATING`: the `GGML_ASSERT(slot.task->need_sampling())` at `tools/server/server-context.cpp:4523` is skipped only by the two early-return branches at `4506-4521`. All their work happens in prefill/decode of the prompt and they release at the first `post_decode` that sees `DONE_PROMPT`.
- **They hold the slot across prompt iterations but never across decode iterations.** Long prompts span multiple `pre_decode/decode/post_decode` iterations (batch fill is capped by `n_batch` at `tools/server/server-context.cpp:3767-3768` and by `can_split()` constraints at `4139-4142`), and the slot stays `SLOT_STATE_PROCESSING_PROMPT` the whole time. Release is one iteration after `DONE_PROMPT` — same `post_decode` call that produced the embeddings.
- Re-batching across the iterations: batch grouping is recomputed per iteration (`batch.clear()` then repopulation at `tools/server/server-context.cpp:3630-3632`); embeddings-mode enable is re-applied per batch at `3457`, so no stale mode leaks between iterations.
- `server_task_type` enum and dispatch make these the only two kinds with this property (`server-task.h:20-23,191-217`).

## B. What the Intermission Policy Already Commits To

Quoted policy (design doc `COHORT_BATCHING_CONTROLLER_DESIGN.md`):

- Entry-side: "If any attached stream still has decode-family work, close ordinary inference admission and drain every such decoder while holding all prompt-family work. Threshold crossing creates only this entry intent, not a cohort." — `COHORT_BATCHING_CONTROLLER_DESIGN.md:17`.
- Intermission: "At that decode boundary, give one ready multimodal task an exclusive intermission before any concurrent prompt cohort begins." — `COHORT_BATCHING_CONTROLLER_DESIGN.md:18`.
- Phase enum includes `COHORT_INTERMISSION` — `COHORT_BATCHING_CONTROLLER_DESIGN.md:331-336`.
- Phase authorization table: `COHORT_INTERMISSION` allows target-work "only for the exact selected multimodal task" and admission "only for that task; helper-internal media rows remain opaque" — `COHORT_BATCHING_CONTROLLER_DESIGN.md:736-744`.
- Blockers: "`cohort_blocker`: attached/running work whose lifecycle or task kind forbids formation even though it is not counted in `R`, including active aLoRA, active multimodal and any still-unreviewed model-state-mutating operation." — `COHORT_BATCHING_CONTROLLER_DESIGN.md:811`. Note the list does **not** name embedding/rerank as blockers; `cohort_capable` explicitly excludes them: "aLoRA, multimodal, embedding and rerank do not" — `COHORT_BATCHING_CONTROLLER_DESIGN.md:810`.
- Exit-side survivor handling: "Exit is committed before the next batch and retains all executor/speculative state. With no ready multimodal task, the zero-work intermission permits NORMAL mixed prompt/decode scheduling in the same scheduling turn." — `COHORT_BATCHING_CONTROLLER_DESIGN.md:1180`.
- Boundary decision: "A decode-side exit enters the multimodal boundary decision before FORM or NORMAL" — `COHORT_BATCHING_CONTROLLER_DESIGN.md:830`; PREFILL-side exit returns directly to NORMAL — `COHORT_BATCHING_CONTROLLER_DESIGN.md:195`.
- Commitments in the numbered invariants: incumbent multimodal blocks entry and finishes exclusively in NORMAL (`:34`, `:1028`); queued multimodal runs only at a decode-side `R <= X` INTERMISSION (`:35`, `:1029`); one oldest task per intermission (`:36`, `:1030`); intermission ends at completion/cancellation even if more are queued (`:38`, `:1032`); survivor re-entry is FORM-or-NORMAL after the intermission (`:1191-1195`).

**Verdict:** the policy commits to embedding/rerank only in the negative — "Embedding and rerank remain NORMAL-only batch work. Their incumbent/queued boundary policy remains in the decision register; the accepted multimodal policy does not silently decide it for them." — `COHORT_BATCHING_CONTROLLER_DESIGN.md:991`. The plan doc repeats the open register item at `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:276` and orders the decision to not be inferred from multimodal: "Keep embedding/rerank under the still-open non-cohort decision; do not infer their policy from multimodal." — `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:820`. Decision 3 is genuinely open; the multimodal policy does not answer it.

## C. Analysis: (a) Finish-in-NORMAL vs (b) Remain-Cohort-Blocker

### Correctness constraints (shared by both options)

- **No cohort membership.** `cohort_capable` excludes embedding and rerank (`COHORT_BATCHING_CONTROLLER_DESIGN.md:810`), so neither option can ever put them inside PREFILL/DECODE. Both options are NORMAL-side policies; the question is only which NORMAL-side interval admits them.
- **Batch homogeneity.** `can_batch_with` requires identical task type, `inp_embd.size` and LoRA (`server-context.cpp:534-539`), and `llama_set_embeddings` is keyed off the first batched slot (`server-context.cpp:3457`). So embedding/rerank cannot be silently folded into a text cohort batch: they would force their own homogeneous batch or be excluded.
- **Prompt-only lifecycle.** They never enter `SLOT_STATE_GENERATING` (`server-context.cpp:4523`); they release immediately after `DONE_PROMPT` (`server-context.cpp:4506-4521`). The only long-lived case is a multi-iteration prefill (prompt > `n_batch`, or pooling-split restrictions, `server-context.cpp:3850-3863,4139-4142`).
- **Speculation.** They are excluded from MTP eligibility at admission under deferred MTP (`server-context.cpp:2897-2904`); no speculative draft is produced for them at post-decode because they return before `common_speculative_begin` (`server-context.cpp:4506-4521` vs `4527-4530`). Speculative state on the slot is aborted in `release()` if a cycle was active (`server-context.cpp:684-686`), which is a no-op here. No speculative-adjacent hazard exists for embedding/rerank batches as long as they stay token-input batches (see E).

### Throughput/latency impact

- **Option (a) Finish-in-NORMAL (before cohort entry).** When `R >= E` fires, control closes inference admission, drains decode-family incumbents, and holds prompts (`COHORT_BATCHING_CONTROLLER_DESIGN.md:17`). If embedding/rerank incumbents are allowed to finish, they run as part of the drain. Since they do not contribute to `R` (`:810`) and are not named blockers (`:811`), the existing predicate machinery would otherwise *hold* them invisibly — queued work stays queue-owned, and attached prompts stay held while `R` drains, which could deadlock prompt slots behind embedding work that the drain never runs. Finishing them first avoids that. Cost: prompt (prefill) throughput during drain is delayed by whatever embeddings batches are interleaved; but because they batch only with their own kind, and typically short-lived (single prefill iteration), the added latency is one or a few prefill decodes.
- **Option (b) Remain-cohort-blocker.** Treating embedding/rerank as blockers (adding them to the `:811` set) means `R >= E` cannot even begin `COHORT_ENTRY_DRAIN` while an embedding/rerank task is attached. Correctness-wise this is safe and matches the incumbent-multimodal precedent (`:34`, `:1028`). Throughput-wise it converts a short-lived prompt task into a cohort-starvation source: a single large-embedding prompt (multi-iteration prefill) blocks all cohort formation even though it is not a decoder and never touches decode-phase machinery. That is a real throughput regression with no correctness gain, since the embedding task cannot legally join the cohort anyway.
- **Latency of embedding/rerank requests themselves:** under (a) they execute in NORMAL ahead of the frozen cohort; under (b) they execute before entry begins. Both have identical worst-case wait (cohort decode-phase latency), but under (a) they can be admitted during the drain window while text decoders finish, hiding their latency behind existing drain work.

### Interaction with ENTRY_DRAIN / FORM thresholds (E/X)

- `R` counts only `independently_runnable_text && cohort_capable` (`COHORT_BATCHING_CONTROLLER_DESIGN.md:810,830`); embedding/rerank never count, so neither E nor X comparisons are affected by them. Option (a) does not change `R`; option (b) adds a non-R side condition (blocker set) to entry.
- Option (a) requires exactly one new predicate: while in `COHORT_ENTRY_DRAIN`, treat NORMAL-only task kinds (embedding/rerank) as drainable work and grant them NORMAL target authorization until their `DONE_PROMPT` release. This is a pure relaxation of the existing "Frozen admission during drain" rule (`COHORT_BATCHING_CONTROLLER_DESIGN.md:1183`), scoped to these two kinds.
- Option (b) requires extending the `cohort_blocker` definition at `:811` to include embedding/rerank, and then blocking `R >= E` entry until the blocker set is empty — matching the incumbent-multimodal precedent (`:34`). It also implicitly forbids admitting new embedding/rerank arrivals during any cohort phase (they are queue-owned until the boundary), which is consistent with `:1184`.

### Interaction with one-task INTERMISSION survivor rules

- The INTERMISSION is decode-boundary-only (`:195`), picks one oldest multimodal task (`:36`), and returns survivors to FORM/NORMAL (`:1191-1195`). Embedding/rerank under option (a) never reach the INTERMISSION: they cleared before FORM. Under option (b) they also never reach it, because they block entry earlier and clear before any cohort phase. Under a hybrid that let *queued* embedding/rerank run at the INTERMISSION, they would compete with the multimodal priority (`:18`) and break the "one-task" quota semantics — nothing in the design reserves intermission slots for them.
- Embedding/rerank tasks do not create decode survivors (they release at `DONE_PROMPT`), so neither option disturbs the survivor-holding rule `:1180-1181` or replay-through-intermission `:1181`.

## D. Decision-Ready Recommendation

**Choose option (a), with a precise boundary predicate — short-lived NORMAL finish before FORM, no INTERMISSION path.**

Specifically:

1. Keep embedding/rerank out of `cohort_capable` and out of `cohort_blocker` (no change to `COHORT_BATCHING_CONTROLLER_DESIGN.md:810-811`).
2. During `COHORT_ENTRY_DRAIN`, admit and run `SERVER_TASK_TYPE_EMBEDDING` and `SERVER_TASK_TYPE_RERANK` tasks (incumbent and queued) under NORMAL target authorization until each releases at `DONE_PROMPT`; they drain alongside decode-family work.
3. At FORM freeze, do not admit any new embedding/rerank tasks; queued ones remain queue-owned until the cohort lifecycle ends (this follows from `:1183-1184` unchanged).
4. No embedding/rerank work in `COHORT_INTERMISSION` — the INTERMISSION stays reserved for the one multimodal task (`:18,:36`). The zero-work intermission path (`:1180`) already covers the boundary with no ready multimodal task.
5. Long-lived embeddings (multi-iteration prefill) need no special case: they are prompt work, they run in NORMAL or in the drain window, and their release rule is unchanged. The one caveat worth registering: a drain window occupied by a very large embedding prefill delays FORM, but this is the same behavior NORMAL already exhibits today; adding a blocker (option b) would only make it worse.
6. Predicate definition for implementation: `drainable_prompt_kind(task) = (task.type == EMBEDDING || task.type == RERANK)`, granted NORMAL authorization while `phase == COHORT_ENTRY_DRAIN`, terminated on release/cancellation. This is the minimal change to the phase table at `COHORT_BATCHING_CONTROLLER_DESIGN.md:736-744` (ENTRY_DRAIN row: prompt-family admission changes from "Forbidden" to "Forbidden except embedding/rerank drain").

Rationale: source shows embedding/rerank are prompt-only, same-kind-batched, release-on-first-post-decode tasks (`server-context.cpp:4506-4521`) that cannot join a cohort (`COHORT_BATCHING_CONTROLLER_DESIGN.md:810`). Blocking them converts an already-bounded short task into an unbounded entry blocker with zero correctness benefit. The finish-in-NORMAL option matches the incumbent-multimodal precedent in spirit (exclusive NORMAL finish, `:34`) while avoiding the deadlock/throughput cost of the full blocker model.

## E. Unsafe Interactions Found Today

- **E1. Embeddings-mode + MTP nextn on embedding-vector batches.** MTP's `need_embd_nextn` disables nextn when `batch_in.token == nullptr || batch_in.embd != nullptr` (`common/speculative.cpp:2114-2118`), and `decode()` hard-throws on `batch.has_embd && spec` with incompatible `n_embd_inp` (`server-context.cpp:4362-4368`). Today's HTTP embedding/rerank path builds token batches (via `server_batch::add(id, token, ...)` at `server-context.cpp:4238-4245`), so the vector-input branch is unreachable through HTTP, but any future controller that synthesizes embedding-vector batches while spec is loaded inherits this trap.
- **E2. Embeddings-mode batch toggle is per-batch and per-first-slot.** `llama_set_embeddings(ctx_tgt, slot_batched->need_embd())` uses only the first batched slot (`server-context.cpp:3457`). If a controller ever mixes an embedding slot into a text slot batch (or vice versa), the mode would be wrong for half the batch. `can_batch_with` prevents this today by task-type equality (`server-context.cpp:534-539`), but a cohort controller that bypasses or re-groups slots without honoring `can_batch_with` would reintroduce it.
- **E3. Split guard depends on pooling type.** Embeddings prompts cannot split unless memory module exists and `LLAMA_POOLING_TYPE_LAST` (`server-context.cpp:524-532`); a controller batching a large embedding prompt under `n_ubatch` assumptions that hold for text prompts will trip the error path at `3850-3863`. Text cohort prefill batching may split; embeddings must not be given those same split allowances.
- **E4. Speculative state on slot release.** `release()` aborts active spec cycles (`server-context.cpp:684-686`) and `reset()` clears spec state (`server-context.cpp:464-469`). If an embedding task is ever admitted onto a slot with a live MTP/ngram cycle (e.g., slot reuse without a completed release), that cycle state is aborted by release. Current mechanics never start a cycle for embedding/rerank (`server-context.cpp:2897-2904,4527-4530` guard), so this is latent, not live.
- **E5. `WAIT_OTHER`/parent-child.** Embedding/rerank tasks can never be parents in the `n_cmpl` machinery (they are created only at `server-context.cpp:5815,6096` without child tasks), but a controller that mistakes `DONE_PROMPT` for `GENERATING` in drain accounting would count them as decoders. They skip `SLOT_STATE_GENERATING` entirely (`server-context.cpp:4506-4521`).

## F. Open Questions

- **F1.** Should queued embedding/rerank arrivals during `COHORT_ENTRY_DRAIN` be admitted immediately (drain-window admission) or only incumbent ones? Source has no admission-time task-kind gate (`select_slots` is kind-agnostic, `server-context.cpp:1908-2066`); the design only freezes admission during drain (`:1183`). Recommendation (a) assumes both incumbent and queued are drainable; if the owner wants to bound drain latency, restricting to incumbents is a plausible refinement but has no source precedent.
- **F2.** Should rerank tasks batch with embedding tasks when their prompts are identical width? Today `can_batch_with` forbids cross-kind batching (`server-context.cpp:534-539`), making large rerank sets slower than they could be; relaxing this is out of scope for decision 3 but worth noting as a follow-up throughput item.
