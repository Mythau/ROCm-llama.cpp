# Deferred MTP Capture — Durable Fix Deep Dive

**Status**: Analysis of a recommended durable fix for the confirmed unbounded-capture defect.
**Date**: 2026-08-16
**Base**: `c448db2d6` (rocm-yolo)
**Companion**: `DEFERRED_MTP_CAPTURE_GROWTH_DEEP_DIVE.md` (claim confirmation, evidence chain)

---

## Problem Restated

A slot admitted in `SLOT_MTP_PREFILL_DEFERRED` mode (server-context.cpp:2901–2903) with
`mtp_capture_active = true` (server-context.cpp:4107–4109) appends hidden rows to the archive on
every target-only decode (`common/speculative.cpp:1702–1726`). Nothing finalizes or bounds the
capture while MTP stays denied, so it grows one row per generated token. The documentation even
codifies this: "Target-only generation continues appending rows while MTP remains deferred"
(`MTP_DEFERRED_PREFILL_IMPLEMENTATION_PLAN.md:166`), and live archives are explicitly outside the
RAM prompt-cache cap (plan:74–77).

This deep dive works through a durable fix candidate-by-candidate, tracing how each candidate
interacts with the full lifecycle: capture states, the speculative cycle interlock, backfill
invariants, admission re-use, prompt save/load, context shift, release, and the
`need_embd_nextn` gate.

---

## The Full State / Lifecycle Inventory

This is the complete set of state that a fix must keep coherent. Every entry cites the working
tree location where it is defined or mutated.

### Slot-side state (tools/server/server-context.cpp)

| State | Definition | Meaning | Mutation sites |
|---|---|---|---|
| `mtp_prefill_mode` | server-context.cpp:286 | TARGET_ONLY / IMMEDIATE / DEFERRED | admission 2978, cache-restore 3016/3019/3022/3025, clear_mtp_archive 338, finalize 350, activation 3519/3540 |
| `mtp_capture_active` | server-context.cpp:287 | builder is live (mirror of impl) | 4093–4111 begin/clear, 331–339 clear, 341–353 finalize |
| `mtp_hidden_archive` | server-context.cpp:289 | finalized immutable archive (shared_ptr) | finalize 347, prefix slice 4093–4107, prompt_save 369, cache restore 3011, reset on clear 334 |
| `mtp_backfill_blocked` | server-context.cpp:288 | retry backoff flag | admission reset 2979, activation retry 3530 |
| `spec_draft`, `spec_i_batch`, `spec_is_replay` | server-context.cpp:280–284 | in-flight speculative cycle | handle_last_sampled_token 643–670, accept 4639–4652 |
| `state` | server-context.cpp:322 | IDLE/STARTED/PROCESSING_PROMPT/DONE_PROMPT/GENERATING | throughout |
| `n_past` (via `n_prompt_tokens_cache`) | server-context.cpp:306 | resolved retained-prefix boundary | 4098–4101 |

### MTP impl-side state (common/speculative.cpp)

| State | Definition | Meaning | Mutation sites |
|---|---|---|---|
| `captures[seq_id]` (builder + pos_next + pending rows) | speculative.cpp:1383–1389 | active capture | begin 1516–1541, append 1721–1724, accept-flush 1979–1985, finalize 1539–1552, discard 1556–1557 |
| `sync[seq_id]` | speculative.cpp:1366 | SYNC_UNKNOWN / SYNC_SYNCHRONIZED / SYNC_INVALID | backfill 1631, verify tail 1758, invalidate 1496 |
| `eligible[seq_id]` (impl-local cache of mask) | speculative.cpp:1367 | set from `eligible_masks` per process call | 1658 |
| `verify_h`, `verify_h_rows`, `pending_h` | speculative.cpp:1372–1376 | per-cycle verification / cross-batch carry | 1748–1760, backfill 1630 |
| `i_last`, `i_batch_beg`, `i_batch_end` | speculative.cpp:1368–1370 | batch bookkeeping | 1661–1677 |

### Global / policy state

| State | Location | Meaning |
|---|---|---|
| `spec->eligible_masks[seq_id]` | speculative.cpp:3044-ish, manipulated at 3145–3180 | authoritative eligibility per seq (MTP mask is what activation needs) |
| `speculative_policy_limits` | server-context.cpp:1176, built 1576–1602 | active-stream limits (MTP limit entry only exists if configured, 1591–1602) |
| `next_mtp_archive_id` | server-context.cpp:1177 | monotonically increasing archive generation counter (used 4101, 4107) |
| `prompt_cache` entries (with `hidden_archive` payload) | server-context.cpp:359–406, 2970–3011 | saved archives attached to cache records |

---

## What Activation Actually Requires (the correctness contract)

`try_activate_deferred_mtp` (server-context.cpp:3502–3541) is the only promotion path. Its
preconditions, in order:

1. **Mode gate**: `mtp_prefill_mode == SLOT_MTP_PREFILL_DEFERRED` (3503).
2. **No backfill backoff**: `!mtp_backfill_blocked` (3503–3504).
3. **Cycle idle**: `spec_cycle_idle()` — no draft tokens, empty `spec_i_batch`, no replay, and
   `common_speculative_cycle_active(spec,id)` false (server-context.cpp:568–574, speculative.cpp:3433–3438).
4. **Policy allows**: `server_speculative_allowed_mask(...)` includes the MTP bit
   (server-context.cpp:3507–3513; policy itself at server-speculative-policy.cpp:3–14).
5. **Archive valid**: after `finalize_mtp_archive()`, `mtp_hidden_archive` non-null (3517–3520).
   `capture_finalize` requires `capture.pos_next == pos_end + 1` where `pos_end` is the *current*
   target `pos_max` (speculative.cpp:1539–1552; server-context.cpp:346–347).
6. **Backfill invariant**: `common_speculative_mtp_backfill` asserts
   `archive.pos_first == 0`, `row_count == pos_end + 1`, and requires
   `llama_memory_seq_pos_max(ctx_tgt) == archive.pos_end` (speculative.cpp:1565–1576). If the
   target has advanced past the archive end, backfill returns `INVALID` and the server drops the
   archive (server-context.cpp:3526–3529).

**Consequence**: any fix that finalizes the capture and *keeps* `capture_active == false` while
target generation continues will produce a stale archive. The next `try_activate_deferred_mtp`
call will either hit the `pos_end != pos_max` mismatch (INVALID → `clear_mtp_archive()`,
server-context.cpp:3526–3529) or, if the slot was resumed from a restored archive, silently fail
the backfill. So "finalize once at prompt completion" is not just suboptimal — it destroys
late-activation correctness for any subsequent generated token. This was flagged in the companion
findings, and this section is the formal proof: the backfill contract is *live-position-tied*,
not prompt-bound.

---

## Candidate Fixes — Full Lifecycle Analysis

### Candidate A — Finalize at prompt completion when activation denied

**Mechanism**: at the `DONE_PROMPT → GENERATING` transition (server-context.cpp:4497–4518), when
`try_activate_deferred_mtp` returns without activating, call `finalize_mtp_archive()` and leave
`capture_active == false`.

**Trace**:
- After finalize, `capture_active` is false → `process()` skips append (speculative.cpp:1703).
- Next target decode advances `pos_max`. If activation is later attempted, backfill sees
  `pos_max != archive.pos_end` → `INVALID` → archive dropped (server-context.cpp:3526–3529). **Late
  activation is permanently broken for this request** — this is the exact scenario
  `try_activate_deferred_mtp` was built for.
- If no later activation, the archive is now *bounded* — correct behavior, but only because the
  feature stopped working.

**Verdict**: **Reject as primary fix.** It trades unbounded growth for broken late activation.
Could be acceptable only if combined with a "never re-activate after prompt completion" policy
(which is Candidate C and a control-committed decision, not a mechanical one).

### Candidate B — Finalize before each backfill attempt in the post-decode scan

**Mechanism**: move `finalize_mtp_archive()` ahead of the policy check inside
`try_activate_deferred_mtp` (server-context.cpp:3517 currently sits *after* the allowed-mask
early-return at 3513). Then re-open capture on denial.

**Trace**:
- The activation attempt is called at two sites: `pre_decode` (server-context.cpp:3616) for every
  generating slot each iteration, and `post_decode` at the prompt→GEN boundary
  (server-context.cpp:4516).
- If MTP is allowed: finalize-then-backfill works; the sequence is exactly what already happens
  (server-context.cpp:3517–3540).
- If MTP is denied: the archive is finalized but capture is now inactive. If we stop there, this is
  Candidate A with the same staleness defect. **Must** be paired with re-opening capture
  (Candidate E below).
- The finalize cost: `common_speculative_hidden_archive_builder_finalize` just moves the builder's
  `blocks` vector into the immutable archive (speculative-archive.cpp:153–164). **O(#blocks), no
  row copy**. The re-open cost with prefix is O(1) vector copy
  (`builder_init`, speculative-archive.cpp:77–93).

**Verdict**: **Correct, but incomplete without Candidate E.** This is the mechanical core of the
recommended fix.

### Candidate C — Stop capture at prompt completion if ineligible and never re-activate

**Mechanism**: at prompt→GEN, if policy denies MTP, finalize and set `mtp_prefill_mode =
SLOT_MTP_PREFILL_TARGET_ONLY`, clearing all future activation.

**Trace**:
- `mtp_prefill_mode` target-only means `try_activate_deferred_mtp` early-returns forever
  (server-context.cpp:3503).
- `need_embd_nextn` gate: `capture_active` false, `eligible` false (MTP mask stripped at admission,
  server-context.cpp:2899/2959–2964) → NextN turns off. **DRAM growth AND the NextN cost both
  stop.**
- The archive is preserved (not cleared) so prompt_save can still cache it; but it will never be
  used for activation — only as a cache payload for future requests.

**Verdict**: **Correct memory behavior, but changes product semantics** — this is a policy
decision (give up on late activation), not a mechanical optimization. It is exactly the kind of
choice that belongs to control/executor coordination: the mechanical layer can implement it, but
only control should decide whether deferred MTP should be "prompt-completion-or-nothing" vs.
"keep trying during generation."

### Candidate D — Cap archive size / evict oldest blocks

**Mechanism**: bound the builder at `K` rows; drop oldest blocks beyond `K`.

**Trace**:
- Backfill asserts `pos_first == 0` and `row_count == pos_end + 1` (speculative.cpp:1565–1567).
  Evicting the head violates both. The archive becomes un-backfillable *by construction*.
- A windowed archive would require a wholly new activation path (partial backfill from an
  arbitrary start position into a fresh draft context), which does not exist today. The current
  MTP model needs full-context reconstruction because the MTP head's hidden-state carry starts at
  position 0 of the sequence (`backfill` loops from row 0, speculative.cpp:1585–1619).

**Verdict**: **Reject.** The invariants are baked into both the archive and the backfill
consumer. Capping at the archive layer without reworking backfill semantics breaks the feature.
A memory cap belongs at admission/policy level (see Control decisions below).

### Candidate E — Finalize-then-reopen capture on each denied activation attempt

**Mechanism**: at each denied `try_activate_deferred_mtp`, finalize the current builder, then
immediately `common_speculative_mtp_capture_begin` with the finalized archive as prefix.

**Trace**:
- `capture_begin` asserts prefix continuity (`pos_end + 1 == pos_first`, speculative.cpp:1526–1533),
  then `reset(seq_id)` — which destroys the previous builder via `captures[seq_id] = {}` in
  `reset` (speculative.cpp:1496). Note `reset` also calls `invalidate`, which clears
  `verify_h`, `i_last`, and — critically — `eligible[seq_id]` is set false at
  speculative.cpp:1502. But `eligible` is re-derived from `eligible_masks` on every `process()`
  call (speculative.cpp:1658), so this is transient.
- **CRITICAL — `need_embd_nextn` cost**: the re-opened capture keeps `capture_active(seq_id)`
  true, so the NextN gate (speculative.cpp:2114–2134) remains true for every target decode.
  Candidate E **bounds DRAM growth but does not stop the NextN cost.** The `llama_set_embeddings_nextn(ctx_tgt, true, ...)`
  is applied every batch (server-context.cpp:4360–4361), and the context copies hidden rows out of
  the backend (llama-context.cpp:1544–1551, `ggml_backend_tensor_get_async`). On
  Vulkan/ROCm/CUDA-managed-memory this is often a cheap host-visible read; on classic CUDA it is
  a device→host transfer per batch. Whether this matters must be measured — **UNVERIFIED** for the
  specific ROCm/Vulkan backend used by this working tree.
- **The pending-row race**: if a speculative cycle from another impl (e.g. ngram) verifies while
  capture is active, rows go to `capture.pending_tokens/pending_rows` instead of being appended
  (speculative.cpp:1714–1719). They are flushed on `common_speculative_accept` (speculative.cpp:1975–1986).
  A finalize between verification and accept would *drop* pending rows and produce an archive
  missing the verified positions. **This is why finalize must happen only at `spec_cycle_idle()`
  boundaries** — the existing precondition at server-context.cpp:3503–3504 already guarantees no
  cycle is in flight for this slot. The fix must preserve this precondition.
- **Archive identity**: each reopen consumes a new `next_mtp_archive_id` (server-context.cpp:1177).
  This is fine — ids are only used for trace/debug (`info.id`).

**Verdict**: **Correct for DRAM bounding. The mechanical heart of the recommended fix, combined
with Candidate B's ordering.** Does not solve the NextN cost (see Candidate F).

### Candidate F — Narrow `need_embd_nextn` to eligible-only capture

**Mechanism**: change the MTP `need_embd_nextn` override to *not* return true merely because a
capture is active; return true only when the MTP mask is eligible, or when the capture actually
needs rows from this specific batch.

**Trace**:
- Capture appends require `llama_get_embeddings_nextn_ith` (speculative.cpp:1711). If
  `need_embd_nextn` is false, the context disables NextN output — the hidden rows won't exist.
- When could a capture NOT need NextN? Never — capturing hidden rows is the whole point. The only
  question is whether the *target model* can cheaply provide those rows when asked. `llama-context.cpp:2061`
  sizes `embd_nextn` from `cparams.embeddings_nextn` at buffer-alloc time; turning it off and on
  per batch is cheap (server-context.cpp:4360–4361 just toggles the flag), but the capture MUST
  request it for every batch it wants to record. **There is no way to skip the NextN extraction
  while still capturing.**
- What CAN change: the *scope* of the flag. Today `need_embd_nextn` returns true for a capturing
  seq even during prompt processing when the MTP mask is stripped. That is correct and required —
  capture needs every row.

**Verdict**: **Reject as a mechanism to stop capture.** It would silently break the archive
contents (missing rows → contiguity assert at speculative.cpp:1709, or worse, wrong rows). The
NextN cost is intrinsic to capture. If that cost is unacceptable, the only real options are
Candidate C (stop capturing) or making the capture itself cheaper (e.g., keeping NextN in
host-visible memory, which the backend may already do — backend-specific, UNVERIFIED).

### Candidate G — Budget-based admission (bound total live capture)

**Mechanism**: a global byte budget for live (unfinalized) archives; when the budget is exceeded,
either demote a deferred slot to target-only (finalize and give up) or refuse deferred admission.

**Trace**:
- Live archives are explicitly out of the prompt-cache accounting (plan:74–77, and
  `prompt_save` only counts the finalized archive, server-context.cpp:369–373).
- There is no existing "live memory" accounting anywhere in the server context. This would be a
  new mechanism touching admission (`server_speculative_plan_occupancy` and its callers at
  server-context.cpp:2885–2890) and slot state.
- This is exactly what the plan calls out: "If a total live-archive cap is later required, it
  belongs to server resource admission" (plan:96–99).

**Verdict**: **Valid, but a control-committed feature.** Not a mechanical fix; requires product
decisions (budget size, demotion policy, eviction-vs-refusal). Do not mix into the mechanical
fix.

---

## Recommended Durable Fix

### Principle

The defect has two parts: unbounded DRAM growth (must fix mechanically) and a per-step NextN
extraction cost (intrinsic to capture, backend-sensitive, and a control decision). The fix below
bounds DRAM without changing any user-visible policy and without touching the capture/backfill
contracts.

### Design

Make the capture **piecewise-bounded**: finalize at every denied activation boundary, then
re-open capture with the finalized archive as prefix. The capture still covers the full target
sequence (contiguity and `pos_first == 0` preserved via prefix), so late activation remains
exactly as correct as today. The only new bound is that the *mutable builder* never spans more
than one decode iteration.

**Changes required** (mechanical executor scope):

1. **server-context.cpp:3502–3541** (`try_activate_deferred_mtp`):
   - Keep the existing early-return guards (mode, backfill-blocked, cycle-idle).
   - **Move** `finalize_mtp_archive()` (currently at 3517) to *before* the allowed-mask check.
   - If `!mtp_hidden_archive` after finalize → demote to target-only (existing logic at 3519–3520).
   - If MTP allowed → proceed with backfill (existing 3521–3540).
   - If MTP denied → **re-open capture**:
     ```cpp
     const auto info = common_speculative_hidden_archive_get_info(slot.mtp_hidden_archive);
     common_speculative_mtp_capture_begin(
         spec.get(), slot.id, next_mtp_archive_id++,
         info.pos_end + 1, slot.mtp_hidden_archive);
     slot.mtp_hidden_archive.reset();
     slot.mtp_capture_active = true;
     ```
     (mirrors the existing begin path at server-context.cpp:4093–4109).

2. **No changes to `common/speculative.cpp` capture primitives.** `capture_begin` already
   supports prefix continuation (speculative.cpp:1516–1541), `finalize` already validates
   continuity (speculative.cpp:1539–1552), and `builder_init` already reuses prefix blocks
   without copying (speculative-archive.cpp:77–93).

3. **No changes to the archive** (`speculative-archive.cpp`). Blocks are immutable once appended;
   the prefix slice shares them by reference (speculative-archive.cpp:43–52, 169–189). Each
   reopen therefore costs O(#blocks) pointer copies, not O(rows).

### Lifecycle interactions (why this is safe)

- **Speculative cycle interlock**: finalize happens only under `spec_cycle_idle()` (guard at
  3503–3504), so `capture.pending_tokens` cannot be dropped mid-cycle; the pending flush path
  (speculative.cpp:1975–1986) is never racing a finalize.
- **Context shift**: happens in `pre_decode` *before* the activation scan (server-context.cpp:3548–3608
  shift logic, then 3614–3618 activation). Shift already calls `clear_mtp_archive()`
  (server-context.cpp:3589), so no stale archive survives to the reopen path.
- **Release**: `release()` finalizes when DEFERRED (server-context.cpp:691–692). With the fix, the
  archive is at most one iteration stale at any moment; `release` semantics unchanged.
- **Prompt save**: `prompt_save()` finalizes first (server-context.cpp:359) and then counts
  `retained_bytes` (server-context.cpp:369–373). With the fix the archive is already finalize-fresh
  (the second finalize is a no-op because `capture_active` is false at idle). **Note**: because
  the fix finalizes at every denied activation attempt, `prompt_save` may now see the archive as
  a *finalized* object even mid-generation. This is a semantic improvement (the cache gets a
  consistent snapshot) and matches plan:173–176.
- **Admission / resident reuse**: the archive is re-finalized and re-opened with a new generation
  id each attempt; `keep_resident_archive` at admission (server-context.cpp:2969–2972) and the
  prefix slice at 4093–4107 continue to work because the archive still covers positions
  `[0, pos_max]` at all times.
- **`mtp_backfill_blocked`**: unchanged — a `RETRY` backfill still sets the flag
  (server-context.cpp:3529–3531) and the next activation attempt is skipped by the existing
  guard; the reopen does not run while blocked, so the bounded-builder property holds trivially
  during backoff (capture stays active and grows during backoff — see Open questions).
- **Multi-slot batching**: the reopen only touches one slot's capture; other slots' `captures[]`
  entries and `i_batch_beg/end` are untouched. `process()` re-derives `eligible[]` from the batch
  (speculative.cpp:1658), so no cross-slot invalidation.

### What this does NOT fix (and must not be silently claimed)

- **The NextN extraction cost**: every target decode still pays `ggml_backend_tensor_get_async`
  for the hidden rows while capture is active (llama-context.cpp:1544–1551). This is
  **intrinsic** to capture. Whether it is a real cost depends on backend memory placement —
  **UNVERIFIED** on the ROCm/Vulkan backends of this working tree.
- **Cross-slot memory**: if many deferred slots are all capturing during generation, total DRAM is
  N × (prompt rows + generated rows). The fix bounds each slot's *mutable* growth to one
  iteration, but the finalized archives still grow with every generated token (one immutable
  block per iteration, sharing all prior blocks via prefix). Total memory still grows linearly
  with total generated tokens across all deferred slots. Only Candidate G (budget admission) or
  Candidate C (stop capturing) addresses this.
- **Backfill backoff growth**: while `mtp_backfill_blocked` is true, the guard at
  server-context.cpp:3503–3504 skips the finalize entirely, so capture resumes unbounded growth
  during the backoff window. The fix bounds growth only when activation attempts occur. If
  backfill retries are rare or the backoff window is short, this is a non-issue; otherwise it is
  a residual defect. See Open questions.

---

## Control vs. Mechanical Decision Boundary

The architecture assigns timing/ownership to control and raw mechanics to the executor. This
partition follows that assignment:

**Mechanical executor actions (do without asking)**:
- Reorder finalize before the policy check in `try_activate_deferred_mtp`.
- Reopen capture with prefix on denial.
- Preserve all existing guards, invariants, and archive semantics.
- Add a trace line (SLT_TRC / SLT_INF) so the finalize/reopen frequency is observable.

**Control-committed decisions (must be explicitly decided before further work)**:
- **Candidate C policy**: should a slot give up on late activation at prompt completion? If yes,
  the mechanical fix degenerates to "finalize at prompt→GEN and demote to target-only" — simpler,
  but changes behavior for requests that would have activated mid-generation.
- **Candidate G budget**: is there a total live-archive memory budget, and what is the demotion
  policy when exceeded?
- **NextN cost acceptance**: if per-step NextN extraction on some backend is too expensive, the
  only mechanical response is to stop capturing (C) or rework the extraction path — both are
  policy-level.
- **Backoff-bounded finalize**: should `mtp_backfill_blocked` slots finalize at each blocked
  attempt too (adding the reopen logic to the blocked branch), accepting that their archive is
  finalize-refreshed but not backfillable until unblocked?

---

## Open Questions / UNVERIFIED Items

1. **Backend NextN cost**: is `ggml_backend_tensor_get_async` on the hidden-state tensor
   (llama-context.cpp:1551) a host transfer on ROCm/Vulkan for this tree, or host-visible memory?
   UNVERIFIED — requires per-backend inspection/measurement.
2. **Backoff growth**: during `mtp_backfill_blocked` the fix does not bound growth (guard skips
   finalize). Is the backoff window bounded in practice by the admission cycle? UNVERIFIED.
3. **Finalize/reopen frequency**: activation is attempted every decode iteration
   (server-context.cpp:3616). Is one finalize+reopen per token too much? Mechanically O(#blocks),
   but a control-committed throttle (e.g. attempt only when active-stream count changes) could
   reduce it — UNVERIFIED whether needed.
4. **Reopen and prompt_save races**: `prompt_save` is called from the admission path while other
   slots may be mid-cycle. The fix's finalize is slot-scoped and cycle-idle-guarded; but whether
   prompt_save can run concurrently with a *different* slot's reopen has not been checked —
   UNVERIFIED. (No threading is evident in the call path; server-context appears single-threaded
   per iteration, but the admission path's ownership model deserves a review before merging.)
5. **Archive generation churn**: each reopen creates a new archive generation
   (`next_mtp_archive_id`), and the old finalized archive is shared by the prefix. If the prompt
   cache still holds the *older* generation (saved earlier), two generations of the same
   sequence can coexist — the cache entry and the live slot. `retained_bytes` double-counts
   blocks shared by reference (plan:85–88 acknowledges this). The fix increases the frequency of
   this — UNVERIFIED whether the accounting is acceptable under repeated finalize/reopen.
