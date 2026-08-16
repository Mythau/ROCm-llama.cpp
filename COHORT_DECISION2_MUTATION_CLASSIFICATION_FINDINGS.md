# Consultation Decision 2: Slot/Cache Mutation Operation Classification — Findings

**Status:** READ-ONLY research deliverable for owner ruling (plan item ~272-274, `COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md`).
**Tree:** `2026-08-12/source/llamacpp-yolo-allpatches-gfx1100-gfx1201` @ c448db2d6 (branch `rocm-yolo`).
**Scope:** `tools/server/server-context.cpp`, `server-queue.{h,cpp}`, `server-task.h`, `server-context.h`. All line refs are this tree; all `context` refs are `tools/server/server-context.cpp`, all `queue` refs are `tools/server/server-queue.cpp` unless noted.

## Executive summary

Every queued task is serviced only at a quiescent point between `update_slots()` iterations, never mid-iteration. The queue loop drains all pending tasks, then calls `update_slots()` (queue:142-163); a task that arrives while an iteration runs waits for the next drain (queue:142-153). There is one real exception, the mid-generation sampler control `reasoning_end` (context:3078-3088), and one global-state mutation that takes effect only at the next batch's LoRA application — `params_base.lora_adapters` write (`/lora-adapters` POST). The legacy loop therefore already provides the equivalent of an end-of-iteration boundary for everything except those two paths. The plan's draft set is confirmed with three corrections: (1) `/lora-adapters` GET is IMMEDIATE (read-only), only POST is boundary-gated; (2) `reasoning_end` slot control is a live mid-iteration sampler mutation (by design, sampler-local only); (3) the `NEXT_RESPONSE`/queue-ordering churn is IMMEDIATE queue-internal state.

Two classification-relevant categories remain UNVERIFIED from source: `common_speculative_*` hidden/ngram pool state (isolation from KV-target state not provable here), and the dormancy/sleep teardown boundary (`handle_sleeping_state` is invoked from inside the queue loop, not between iterations — no evidence in this tree that it is deferred to a quiescent point).

## Queue/lease visibility semantics (context for the classifications)

- Main loop: drain all pending tasks → `callback_update_slots()` = one inference iteration (pre_decode/render → decode views → post_decode) → wait for new tasks (queue:142-163). `start_loop` is registered with `on_new_task → process_single_task`, `on_update_slots → update_slots` (context:1756-1761).
- Tasks do not preempt an in-flight iteration: a task posted during `update_slots()` is processed by the next loop pass (queue:142-153). `update_slots()` itself posts `NEXT_RESPONSE` each iteration, so an extra loop pass follows every iteration (context:3421-3427).
- `front=true` posts do not bypass the boundary; they only reorder within the next drain. Used by metrics/slots (`res->rd.post_task(std::move(task), true)`, context:5142, 5282) and by cancellation (`queue_tasks.post(std::move(cancel_tasks), true)`, queue:456).
- Cancellation path: reader `stop()` removes waiting ids, builds `CANCEL` tasks with `id_target`, posts at queue front (queue:441-457); `server_queue::post()` additionally erases any queued/deferred task with the same id (`cleanup_pending_task`, queue:25-28, 47-51, 211-222); the `CANCEL` task itself finds the slot whose `slot.task->id == id_target` and calls `slot.release()` (context:3053-3062). A lease is simply a queued task's `id`; there is no executor-side lease object — running work is reached only via the `CANCEL` task scanning live slots.
- `slot.release()` (context:678-707): if a spec cycle is live, `abort_spec_cycle()` (clears MTP archive, `mem.seq_rm`, prompt, prompt-cache key, abandons cycle, clears draft/i_batch/ckpt state — context:587-606), finalizes deferred MTP archive, sets `SLOT_STATE_IDLE`, clears prompt for child slots, resets, fires `callback_on_release` (which releases `WAIT_OTHER` children and calls `queue_tasks.pop_deferred_task(id_slot)` — context:1656-1668; queue:77-104). All of it is slot-local.

## Task kinds and what they mutate (server-task.h:19-33)

`COMPLETION`, `EMBEDDING`, `RERANK`, `INFILL`, `CANCEL`, `CONTROL`, `NEXT_RESPONSE`, `METRICS`, `SLOT_SAVE`, `SLOT_RESTORE`, `SLOT_ERASE`, `GET_LORA`, `SET_LORA`. Slot states: `IDLE`, `WAIT_OTHER`, `STARTED`, `PROCESSING_PROMPT`, `DONE_PROMPT`, `GENERATING` (context:60-67); `is_processing() = state != IDLE` (context:560-562).

## A. Complete operation inventory

| Operation | Current call site(s) | State touched | Classification | Minimal safe boundary | Evidence |
| --- | --- | --- | --- | --- | --- |
| Completion / infill admission (`COMPLETION`, `INFILL`) | `process_single_task` 2819-2822, 2834-3051 | Target slot: prompt/KV/memory, LoRA, sampler, speculative masks, prompt cache | BOUNDARY-GATED (inherently — it is the inference work itself) | End-of-iteration (slot settlement via `release`/defer) | 2819-2822, `prepare_slot_launch` 2142-2248, `attach_prepared_slot` 2251-2288, cache save/load 2911-3032 |
| Embedding / rerank admission (`EMBEDDING`, `RERANK`) | 2821-2822, 6096+, 5815 | Target slot KV/logits, then `slot.release()` | BOUNDARY-GATED (inference work) | End-of-iteration | 2819-2822; release at 4507-4518 |
| Deferred re-queue of above when no slot | 2840-2858 | `queue_tasks_deferred` ordering | IMMEDIATE (queue-internal) | none | `defer()` 2843, 2850, 2857; queue:63-68 |
| Prompt-cache save/load on task admission (`cache_prompt` intent) | 2911-2932, `prompt_cache->update()` 3029-3032 | RAM prompt cache + parent-slot prompt/KV via `prompt_cache->apply` | BOUNDARY-GATED | End-of-iteration (task-handler time, i.e. already between iterations) | `prompt_save` 352-385; `take`/`apply` 2914-3027 |
| Cache-idle-slot save/clear | 3034-3050 | Idle slots only: `prompt_save`, `prompt_cache->update()`, and (kv_unified) `prompt_clear` + key clear | BOUNDARY-GATED (but touches only `!is_processing()` slots, 3036) | End-of-iteration | 3034-3050 |
| `CANCEL` task (`/v1/...` disconnect, reader `stop()`) | `process_single_task` 3053-3062; queue:441-457; queue:211-222 | Pending queue purge (queue-internal), then live slot `release()` (KV/mem/spec slot state) | Split: pending-queue purge IMMEDIATE; live-slot release BOUNDARY-GATED | End-of-iteration (already where the task runs) | queue:25-28, 211-222; 3053-3062 |
| `CONTROL` `reasoning_end` (slot control action) | 3063-3095 | Live sampler's reasoning budget, mid generation ("act on the live slot mid generation, never defer", 3086-3087) | UNCLASSIFIABLE as IMMEDIATE: by-design mid-iteration sampler mutation, but strictly sampler-local (no KV/prompt/cache/spec) | none (intentional); keep as explicit IMMEDIATE-mid-generation exception | 3078-3088 |
| `NEXT_RESPONSE` | 3096-3099; posted from `update_slots` 3421-3427 | nothing | IMMEDIATE (queue-ordering no-op) | none | 3096-3099 |
| `METRICS` (also serves `/slots`) | 3100-3162; routes 5131-5311 | `metrics` counters (`reset_bucket`, 3158-3160); read-only slot serialization | IMMEDIATE (metrics only; `reset_bucket` is observability) | none | 3100-3162; `to_json` slot data 3107-3120 |
| `GET_LORA` (`/lora-adapters` GET) | 3287-3312; route 5852-5878 | none (reads `params_base.lora_adapters` + vocab) | IMMEDIATE (read-only) | none | 3287-3312 |
| `SET_LORA` (`/lora-adapters` POST) | 3313-3325; route 5880-5912 | Global `params_base.lora_adapters = new_loras` | BOUNDARY-GATED (global model-state policy; note: takes effect only at next `common_set_adapter_lora` per batch, 3447-3448) | End-of-iteration / controller phase transition (see E) | 3313-3325 |
| `SLOT_SAVE` (`/slots/:id` save) | 3163-3202; route 5936-5970 | File write; requires `!slot->is_processing()` else defers (3174-3178) | BOUNDARY-GATED (slot file op) | Slot idle (already enforced by defer) | 3163-3202 |
| `SLOT_RESTORE` (`/slots/:id` restore) | 3203-3255; route 5972-6007 | Target slot KV/mem (`llama_state_seq_load_file`), draft KV removed, MTP archive cleared, spec demoted, prompt replaced; requires idle else defers (3211-3215) | BOUNDARY-GATED (slot KV/spec state) | Slot idle (already enforced by defer) | 3203-3255 |
| `SLOT_ERASE` (`/slots/:id` erase) | 3256-3286; route 6009-6034 | `prompt_clear()` + key clear; requires idle else defers (3268-3272) | BOUNDARY-GATED (slot KV/prompt) | Slot idle (already enforced by defer) | 3256-3286 |
| `prompt_clear` inside `select_slots` purge | 2082-2098 | Idle slot with resident prompt, evicted under memory pressure | BOUNDARY-GATED (slot KV) | Slot idle (guard at 2083-2085) | 2082-2098 |
| Context shift | 3597-3625 | `clear_mtp_archive`, spec demote, `mem.seq_rm/seq_add`, prompt token rewrite | BOUNDARY-GATED (KV + spec) | End-of-decode inside `post_decode`; runs in the iteration itself | 3597-3625 |
| `release()` (normal/stop/error paths) | 3574, 3586, 3838, 3846, 3858, 3869, 3879, 4204, 4407, 4510, 4517, 4581, 4704; `abort_all_slots` 3353-3359 | Slot KV/mem/spec/MTP, `SLOT_STATE_IDLE`, child release + deferred re-pop | BOUNDARY-GATED (slot lifecycle) | End-of-iteration/post-decode where it already runs | 678-707; 3353-3359; 1656-1668 |
| Decode-failure whole-context clear | 4404-4417 | All processing slots: `send_error`, `release`, then `prompt_clear` + key clear; throws to abort iteration | BOUNDARY-GATED (unsafe-today: also see D) | End-of-iteration | 4401-4417 |
| `abort_all_slots` on pre/decode/post exceptions | 3436, 3487, 3496 | All processing slots released | BOUNDARY-GATED (emergency path) | End-of-iteration (runs inside `update_slots`) | 3353-3359; 3430-3498 |
| Deferred MTP activation / backfill | 3501-3508, 3511-3559 | Per-slot MTP archive capture/backfill after verification | BOUNDARY-GATED (spec runtime) | End-of-post-decode (already positioned at 3501-3508) | 3501-3559 |
| Resident spec demote (prompt-suffix reprocessing) | 3827-3830, 3935-3936, 4090, 4097 | Spec mask disable on live slot during prompt processing | BOUNDARY-GATED (spec state) | Within iteration, slot-local | 3827-3830, 3935-3936, 4090-4097 |
| `/health` (`GET /health`, `/v1/health`) | route 5118-5129; registered server.cpp:244-245 | none (`{"status":"ok"}`) | IMMEDIATE (no queue task at all; bypasses sleep) | none | 5118-5129 |
| `/metrics` route + `METRICS` task | route 5131-5269 | see `METRICS` row | IMMEDIATE | none | 5131-5269 |
| `/slots` GET route | 5271-5312 (uses `METRICS` task) | see `METRICS` row | IMMEDIATE (read-only) | none | 5271-5312 |
| Shutdown signal (`server_context::terminate`) | 4741-4743 | `server_queue::running=false` + notify | IMMEDIATE (stop signal, queue-internal) | none (ends the loop) | 4741-4743; queue:139-147; queue:168-171 |
| Sleeping state enter/exit (`handle_sleeping_state`) | 1227-1239; registered 1762-1764 | Destroy/reload model and contexts (`destroy()` 1211-1225, `load_model`) | BOUNDARY-GATED (global model teardown) | Controller phase transition — but see UNVERIFIED (boundary timing not provable) | 1227-1239; queue:178-196 (invoked from inside the loop) |
| Speculative policy (occupancy/demotion decisions) | 2886-2994, 3523-3538 | Per-slot mask demotion/reset at admission and after verification | BOUNDARY-GATED (spec admission) | End-of-iteration (policy computed per iteration) | 2886-2994, 3523-3538 |

## B. Exact IMMEDIATE set (verify the plan's draft list)

The draft list is correct in substance: **cancellation, metrics, health, shutdown signalling** are IMMEDIATE, with these source-verified nuances:

- Cancellation — the queue-internal part (pending-task purge, queue:211-222; posting at front, queue:441-457) is IMMEDIATE. The live-slot `release()` half (context:3053-3062) is boundary-gated by construction: it only executes at the next task-drain, which is already an end-of-iteration boundary (queue:142-163). Net: cancellations may be *signalled* immediately and are *effected* at the next iteration boundary; no executor-side lease or in-flight decode mutation exists.
- Metrics — `SERVER_TASK_TYPE_METRICS` touches only `metrics` counters, slot JSON serialization, and `metrics.reset_bucket()` (context:3100-3162). No KV/prompt/spec/cache state. IMMEDIATE.
- Health — `/health` never enters the queue and returns a static JSON status (context:5118-5129); it is also sleep-bypass (`create_response(true)`, context:5120). IMMEDIATE.
- Shutdown signalling — `terminate()` sets `running=false` and notifies (context:4741-4743); the loop checks it at its next queue inspection (queue:144-147). IMMEDIATE.
- Additional confirmed IMMEDIATE: `NEXT_RESPONSE` (no-op, context:3096-3099), `GET_LORA` (read-only, context:3287-3312), `/slots` GET (read-only, uses the metrics task, context:5271-5312), and the queue-internal deferred/pending reordering (queue:63-68, 77-104).
- Explicit mid-generation exception: `reasoning_end` (context:3078-3088) is an IMMEDIATE mutation of a live sampler by design ("act on the live slot mid generation, never defer"). It is sampler-local only — it does not touch KV, prompt, cache, or speculative runtime.

## C. Exact BOUNDARY-GATED set (verify the draft `/lora-adapters` example)

- `/lora-adapters` POST (`SET_LORA`, context:3313-3325) — confirmed boundary-gated: it rewrites global `params_base.lora_adapters`, consumed by `prepare_slot_launch` for every new task (context:2157-2158) and applied to the backend at the next batch via `common_set_adapter_lora` (context:3447-3448). `/lora-adapters` GET is NOT gated (read-only).
- Adapter changes at task admission — per-request LoRA comparison and cache clearing in `prepare_slot_launch` / `attach_prepared_slot` (context:2146-2156, 2254-2263).
- Prompt cache mutations — `prompt_save`/`take`/`apply`/`update()` during admission (context:2911-2932, 3029-3032) and cache-idle-slot save/clear (context:3034-3050).
- Slot file operations — `SLOT_SAVE` (3163-3202), `SLOT_RESTORE` (3203-3255), `SLOT_ERASE` (3256-3286). Each already defers while the target slot is processing (3174-3178, 3211-3215, 3268-3272), i.e. the code itself enforces slot-idle as the boundary.
- Slot lifecycle — `release()` (678-707), `abort_all_slots` (3353-3359), purge-on-slot-selection `prompt_clear` (2082-2098), context shift (3597-3625).
- Speculative-policy and runtime mutations — occupancy/demotion/reset at admission (2886-2994), resident demote during prompt reprocessing (3827-3830, 3935-3936, 4090-4097), deferred MTP activation/backfill after verification (3501-3559).
- Sleep teardown/reload — `handle_sleeping_state` destroys and reloads model+contexts (1227-1239) — global model state; see UNVERIFIED for the boundary timing caveat.
- Inference admissions themselves (completion/infill/embedding/rerank) are the work, not bypassable side operations.

## D. Unsafe-today mutations found

- **Decode-failure whole-context clear (context:4401-4417).** After a decode error, the loop releases every processing slot and then clears each slot's entire prompt/KV (`prompt_clear`, 4411) before throwing, inside `update_slots` while other slots' iteration state may still be pending (comment at 4409-4410 concedes partial batch progress is untrackable). Under the cohort refactor this is the one legacy mid-iteration global sweep to preserve as an explicit abort path rather than a generic bypass. NOTE: this is the pre-existing legacy behavior and is being reported, not changed.
- **`SET_LORA` global write with in-flight work (context:3313-3325).** The `params_base.lora_adapters` assignment is serviced at the next task-drain, i.e. after the previous iteration settles, but in-flight slots are not re-prepared; the new adapters silently apply only to future batches (3447-3448). This is not a mid-iteration race in the current single-threaded loop, but it is a global-state mutation without a quiescence/version gate — the exact hazard class consultation decision 2 is meant to close.
- **No other true mid-iteration mutation was found.** Cancellation, metrics, health, shutdown, slot save/restore/erase, and GET all land at queue boundaries or enforce idle/defer guards (`slot->is_processing()` checks). `reasoning_end` is the single intentional exception (D-style flag not applicable; see B).

## E. Recommended final classification for owner ruling

Decision-ready proposal, limited to what the source supports:

```text
IMMEDIATE = { cancellation signalling + pending-queue purge, metrics (incl. metrics_reset_bucket),
              /health, /v1/health, /slots GET, /lora-adapters GET,
              NEXT_RESPONSE queue-ordering no-op, shutdown signal (queue terminate),
              reasoning_end slot control (sampler-local, by-design mid-generation exception) };
BOUNDARY-GATED = { /lora-adapters POST (params_base.lora_adapters), per-request adapter changes
                   and adapter-driven cache clearing at slot admission,
                   prompt-cache save/load/apply/update and cache-idle-slot save/clear,
                   /slots save|restore|erase, slot release/purge/context-shift,
                   speculative occupancy/demotion/admission and deferred-MTP backfill,
                   sleep-state model destroy/reload,
                   live-slot release half of cancellation }
  at boundary { end-of-iteration for all queued tasks (the existing task-drain/update_slots
                loop already provides this); slot-idle for /slots file ops (already enforced
                by defer); controller phase transition for sleep/global adapter policy;
                explicit stop/restart for the decode-failure whole-context sweep };
no generic non-inference bypass exists.
```

Supporting structural facts the owner can rely on: the queue drains tasks only between `update_slots()` iterations (queue:142-163); the only mid-iteration exception is the intentionally sampler-local `reasoning_end` (context:3086-3088); `/slots` mutations and purge already defer on `is_processing()` (3174-3178, 3211-3215, 3268-3272, 2083-2085); the only global model-state mutation is `params_base.lora_adapters` (3313-3325), applied at the next batch (3447-3448).

## F. Open questions (genuinely ambiguous from source)

- Sleep/dormancy boundary: `handle_sleeping_state` destroys/reloads model+contexts and is invoked from inside the queue loop's sleep wait (queue:178-196; context:1227-1239). No code in this tree defers it to an end-of-iteration/phase boundary, and this file cannot prove all slots are quiescent when it runs. Owner should confirm whether cohort-mode sleep entry must add an explicit all-slots-settled precondition. UNVERIFIED.
- `common_speculative_*` shared state (hidden archive/ngram-mod pool, `common_speculative_get_ngram_mod_pool_info` at context:3151-3156; demotion/backfill at 2886-2994, 3501-3559) lives outside `tools/server`. Whether any of it is shared across slots or coupled to target-KV such that a mid-iteration change could corrupt a decode cannot be determined from this tree alone. UNVERIFIED.
