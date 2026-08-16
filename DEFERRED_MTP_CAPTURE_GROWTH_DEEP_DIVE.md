# Deferred MTP Capture Growth Deep Dive

**Status**: CONFIRMED — the capture grows unboundedly during target-only generation.
**Date**: 2026-08-16
**Base**: `c448db2d6` (rocm-yolo branch)

---

## Claim

When a slot is admitted with `--spec-mtp-deferred` and MTP is denied by the active-streams policy, the
slot enters target-only decode with `mtp_prefill_mode == SLOT_MTP_PREFILL_DEFERRED` and
`mtp_capture_active == true`. The hidden-state capture keeps recording hidden rows on every generated
token, growing the archive **unboundedly** in DRAM across all target-only decode iterations.
Furthermore, `need_embd_nextn` forces NextN embeddings for the entire capture period, adding a
per-step GPU-compute cost proportional to the hardware (free on Vulkan/ROCm, expensive on CUDA).

**Result**: **CONFIRMED** in both dimensions (unbounded DRAM growth, NextN embedding cost across all
target-only steps).

---

## Evidence Chain

### 1. Admission: deferred mode selected, MTP denied

**File**: `tools/server/server-context.cpp`

- Lines 2893–2902: `slot_mtp_prefill_mode` vector populated. When `params_base.spec_mtp_deferred`
  is set and the occupancy policy denies the MTP mask, the slot gets
  `SLOT_MTP_PREFILL_DEFERRED`.
- Lines 2969–2972: If a cached/resident archive exists, the mode is forced back to
  `SLOT_MTP_PREFILL_DEFERRED` even if immediate was available, and the MTP mask is stripped from the
  incoming policy mask.
- Lines 2974–2978: `incoming.mtp_prefill_mode = mtp_modes[i]` stores the deferred assignment on the
  slot. `clear_mtp_archive` is called unless the parent slot already has a keeper archive.

**Result**: Slot enters prompt processing with `mtp_prefill_mode == SLOT_MTP_PREFILL_DEFERRED`,
`mtp_backfill_blocked == false`, `mtp_capture_active == false`, and the MTP mask stripped from
the speculative eligibility mask.

### 2. Prompt processing: capture begins

**File**: `tools/server/server-context.cpp`, lines 4093–4111

After resident/cache prefix resolution determines `n_past`, when
`mtp_prefill_mode == SLOT_MTP_PREFILL_DEFERRED`:

```
if (slot.mtp_prefill_mode == SLOT_MTP_PREFILL_DEFERRED) {
    common_speculative_hidden_archive_ref prefix;
    if (n_past > 0 && slot.mtp_hidden_archive) {
        // try to slice existing archive for reuse
        ...
    }
    if (n_past == 0 || prefix) {
        common_speculative_mtp_capture_begin(
            spec.get(), slot.id, next_mtp_archive_id++, n_past, std::move(prefix));
        slot.mtp_hidden_archive.reset();
        slot.mtp_capture_active = true;          // <--- CAPTURE ACTIVE
    } else {
        slot.clear_mtp_archive();
    }
}
```

This calls `capture_begin()` on the MTP impl.

### 3. MTP capture_begin: builder initialized

**File**: `common/speculative.cpp`, lines 1516–1541

```cpp
void capture_begin(...) {
    GGML_ASSERT(!is_mem_shared && !chain_heads);
    GGML_ASSERT(pos_first >= 0);
    // validates prefix continuity
    llama_memory_seq_rm(llama_get_memory(params.ctx_dft), seq_id, -1, -1);
    reset(seq_id);
    captures[seq_id].builder = common_speculative_hidden_archive_builder_init(
        archive_id, seq_id, n_embd, GGML_TYPE_F32, std::move(prefix));
    captures[seq_id].pos_next = pos_first;
}
```

Builder is a `vector<slices>` backed by shared-ownership immutable blocks. Blocks are
`vector<float>` with `row_count × n_embd` floats each.

### 4. Every target decode: process() appends rows

**Call path**: `post_decode()` → `llama_decode(ctx_tgt, ...)` → `common_speculative_process()` →
`impl_mtp->process()` → `common_speculative_hidden_archive_builder_append()`

**File**: `common/speculative.cpp`, lines 1702–1726

```
for (llama_seq_id seq_id = 0; ...) {
    if (i_batch_beg[seq_id] < 0 || !capture_active(seq_id)) { continue; }
    auto & capture = captures[seq_id];
    const int32_t n_rows = ...;
    GGML_ASSERT(batch_in.pos[i_batch_beg[seq_id]] == capture.pos_next);

    const float * h = llama_get_embeddings_nextn_ith(ctx_tgt, i_batch_beg[seq_id]);

    if (speculative_verification[seq_id]) {
        // defer — stash pending, commit only on accept()
        capture.pending_tokens.assign(...);
        capture.pending_rows.assign(h, ...);
    } else {
        // TARGET-ONLY PATH: immediate append
        common_speculative_hidden_archive_builder_append(
            capture.builder.get(), capture.pos_next,
            batch_in.token + i_batch_beg[seq_id], h, n_rows);
        capture.pos_next += n_rows;       // <--- GROWS EVERY ITER
    }
}
```

**During target-only generation, `speculative_verification[seq_id]` is 0** (verified at
server-context.cpp:4422–4424: `speculative_verification[slot.id] = !slot.spec_i_batch.empty()` —
empty when no drafts). So **every generate step appends to the archive**.

### 5. need_embd_nextn: forced across capture period

**File**: `common/speculative.cpp`, lines 2114–2137

```cpp
bool need_embd_nextn(...) const override {
    if (batch_in.token == nullptr || batch_in.embd != nullptr) { return false; }
    const uint32_t type_mask = 1u << type;
    for (...) {
        if (capture_active(seq_id) ||                        // <--- CAPTURE => TRUE
            ((eligible_masks[seq_id] & type_mask) && sync[seq_id] != SYNC_INVALID)) {
            return true;
        }
    }
    return false;
}
```

When `capture_active(seq_id)` is true, **every batch with that sequence returns `true`**, regardless
of MTP eligibility. This is invoked at **server-context.cpp:4360–4361**:

```cpp
const bool need_embd_nextn = common_speculative_need_embd_nextn(spec.get(), batch_view);
llama_set_embeddings_nextn(ctx_tgt, need_embd_nextn, /*masked*/ false);
```

This forces `llama_set_embeddings_nextn(ctx_tgt, true, false)` on every target-only decode. The cost
varies by backend:
- **Vulkan / ROCm / no-copy**: negligible — embeddings are already in host-accessible VRAM.
- **CUDA (non-zero-copy)**: forces a GPU→host copy of the `n_embd`-wide hidden vector per token.

### 6. prompt completion → generation transition: no finalize

**File**: `tools/server/server-context.cpp`, lines 4512–4518 (post_decode, prompt→GEN):

```cpp
if (slot.state == SLOT_STATE_DONE_PROMPT) {
    ...
    slot.state = SLOT_STATE_GENERATING;
    if (slot.can_speculate()) {
        try_activate_deferred_mtp(slot);     // will likely fail (MTP denied)
        common_speculative_begin(spec.get(), slot.id, ...);
    }
}
```

`try_activate_deferred_mtp()` calls `finalize_mtp_archive()` if activation succeeds, but if the
policy still denies MTP, the finalize does NOT happen — `capture_active` stays `true` and the
archive keeps growing during generation.

### 7. try_activate_deferred_mtp: activation attempts, but only at safe boundaries

**File**: `tools/server/server-context.cpp`, lines 3502–3541

Two call sites:
- **Site 1** (line 3616): `pre_decode()` — before batch assembly, calls for each GENERATING slot.
- **Site 2** (line 4516): `post_decode()` — at DONE_PROMPT→GENERATING transition.

In both cases, if `server_speculative_allowed_mask` does not include the MTP mask, the function
returns without finalizing. The capture remains active.

### 8. No per-step growth bound

**The source has no mechanism to cap or evict the archive during live target-only generation.**

The archive grows linearly with each generated token. The only termination points are:
- `finalize_mtp_archive()` (finalize and stop capture, starts backfill)
- `clear_mtp_archive()` (discard)
- `capture_discard()` (discard)
- `capture_finalize()` → called by finalize, checks `pos_end + 1 == pos_next` continuity

---

## Growth Model

### Per-token cost

For each generated token during target-only decode with deferred MTP:

```
archive_block rows:    n_rows × n_embd × sizeof(float)   (typically 1 × n_embd × 4)
archive_block tokens:  n_rows × sizeof(llama_token)      (typically 1 × 4)
block struct overhead: ~96 bytes (shared_ptr overhead + vectors)
builder slice entry:   ~48 bytes
```

**Dominant term**: `n_embd × 4` bytes per position.

| n_embd | Per-token cost | Per 1000 tokens | Per 10,000 tokens |
|--------|---------------|-----------------|-------------------|
| 4096   | ~16.4 KiB     | ~16 MiB         | ~160 MiB          |
| 7168   | ~28.7 KiB     | ~28 MiB         | ~280 MiB          |
| 16384  | ~65.5 KiB     | ~64 MiB         | ~640 MiB          |

### Live-request growth ceiling (worst case)

A deferred request that generates `max_tokens` before MTP activation accumulates:

```
max_archive_growth = max_tokens × n_embd × sizeof(float)
```

The implementation plan explicitly states (line 74–77): *"While a request is live, its archive is
live request memory and is not part of the RAM prompt-cache limit."* There is **no per-request cap**
or total live-archive cap.

### Prompt-cache double-counting when saved

When `prompt_save()` runs (server-context.cpp:359–379), the finalized archive's `retained_bytes` is
counted in the prompt cache. If the slot is released with a non-finalized capture,
`release():691–692` calls `finalize_mtp_archive()` which snapshots the full capture. The cache
stores this size but makes no per-request admission decision based on it.

---

## Current Bounds (Every Clear/Drop/Finalize Site)

**File**: `tools/server/server-context.cpp`

| Line(s) | Context | Action | Notes |
|---------|---------|--------|-------|
| 331–339 | `clear_mtp_archive()` definition | Discard builder, reset mode, clear `mtp_hidden_archive` | Called from 7 sites below |
| 341–353 | `finalize_mtp_archive()` definition | Convert builder to immutable archive stored in `mtp_hidden_archive` | No-op if `!capture_active` |
| 359 | `prompt_save()` start | Calls `finalize_mtp_archive()` | Archive goes into cache entry |
| 412 | `prompt_clear()` | Calls `clear_mtp_archive()` | Slot context cleared |
| 591 | `abort_spec_cycle()` | Calls `clear_mtp_archive()` | Full cycle abort |
| 691–692 | `release()` | Calls `finalize_mtp_archive()` if DEFERRED | Final snapshot before idle |
| 2257 | `attach_prepared_slot()` — LoRA change | Calls `clear_mtp_archive()` | Reset on resident LoRA clear |
| 2976 | Admission — incoming slot setup | Calls `clear_mtp_archive()` (unless keep_resident_archive) | Resets for new task |
| 3228 | `process_single_task()` — slot-action | Calls `clear_mtp_archive()` | Explicit slot action |
| 3532 | `try_activate_deferred_mtp()` — backfill invalid | Calls `clear_mtp_archive()` | Archive no longer matches |
| 3589 | `pre_decode()` — context shift | Calls `clear_mtp_archive()` | KV shift invalidates |
| 3923 | Prompt processing — chunk reuse | Calls `clear_mtp_archive()` | KV remapping |
| 4024 | Prompt processing — checkpoint restore | Calls `clear_mtp_archive()` | Restore from checkpoint |
| 4111 | Prompt processing — capture begin failure | Calls `clear_mtp_archive()` | No valid prefix |

**File**: `common/speculative.cpp`

| Line(s) | Context | Action |
|---------|---------|--------|
| 1539–1552 | `capture_finalize()` | Checks `pos_end + 1 == pos_next`, returns finalized archive or empty |
| 1556 | `capture_discard()` | Destroys builder, clears capture state |
| 1508–1510 | `capture_active()` | Returns `builder != nullptr` |

### During target-only generation, NONE of these fires

The capture stays active through:
- Each `process()` call (append, not finalize or discard)
- Each `need_embd_nextn()` call (returns true due to `capture_active`)

The ONLY way capture stops during generation is:
1. `release()` (task ends) — finalizes the full capture
2. Context shift — clears
3. A later admission cycle — can clear on reassignment

---

## Mitigation Options

| # | Mitigation | Preserves late-activation correctness? | Effects on RAM prompt-cache reuse? | Breaks context shift / release semantics? |
|---|-----------|---------------------------------------|-----------------------------------|-----------------------------------------|
| 1 | **Finalize at prompt-completion when activation denied** | **No.** `finalize` sets `capture_active=false`, so `process()` skips append. Late activation would need re-capture — but backfill requires `pos_end == pos_max`, which was true at finalize time. **If the finalized archive captures coverage up to `pos_end` at prompt completion, backfill later works IF no new target tokens were generated.** Since they WILL be generated, the archive is stale. | Archive enters cache at prompt save. Normal. | No break. `release()` already calls `finalize`. |
| 2 | **Finalize before each backfill attempt in post-decode scan** | **Yes**, if `finalize` immediately precedes the `try_activate_deferred_mtp` call at the safe boundary. The archive captures all positions up to the current `pos_max`. The existing code at `try_activate_deferred_mtp:3517` already calls `finalize_mtp_archive()` — but ONLY if MTP is now allowed. | Depends on whether archive is re-used after finalize. The finalized archive replaces the builder, so `process()` would not append because `capture_active()` returns false. A re-capture would be needed if activation fails again. | No break. |
| 3 | **Stop capture at prompt completion if ineligible and never re-activate** | **No.** Closes the door on late activation. The whole point of deferred MTP is to activate later. | Archive would still exist in cache. | No break but defeats the feature. |
| 4 | **Cap archive size / evict oldest blocks** | **Partial.** Truncating old blocks means `pos_first` no longer matches, which **breaks backfill** (`backfill()` asserts `pos_first == 0`). An eviction scheme that drops oldest blocks would violate the backfill contract. | Breaks backfill entirely. | N/A — breaks the feature. |
| 5 | **Close capture after finalize, re-open on activation failure** | **Yes.** `finalize` → immutable archive. If activation fails again, `capture_begin()` with the finalized archive as `prefix`. This means each activation attempt finalizes the current state, and non-activation re-opens capture. The cost is repeated finalize/re-begin pairs. | No change. | No break. |

**Assessment**: Option 5 is the closest to correct but introduces repeated finalize+re-begin overhead.
Option 2 with the modification that `finalize` also happens on DENIAL (not just allowance) is simpler
but means only ONE activation window is supported — if activation fails again, capture stops
permanently.

### Option 6: Close capture on finalize, unconditionally restart capture when denied

This is the hybrid that preserves correctness:

```
try_activate_deferred_mtp(slot):
1. finalize_mtp_archive()          // always, even if denied
2. if MTP allowed:
     backfill → activate
   else:
     // RE-START capture from finalized state
     slot.mtp_hidden_archive = the finalized archive
     capture_begin(..., pos_end+1, archive_as_prefix)
```

This means:
- Every activation attempt snapshots the current state
- If denied, capture resumes from the snapshot boundary
- The per-attempt cost is finalize + re-begin (O(n_embd × row_count) for finalize, O(1) for
  re-begin with prefix)
- The frequency is controlled by how often `try_activate_deferred_mtp` is called (every decode
  step in `pre_decode:3616`)

---

## Recommended Minimal Fix

**The architecture already supports the correct fix.** The only change needed is in
`try_activate_deferred_mtp()` (server-context.cpp:3502–3541):

### What must change

Move `finalize_mtp_archive()` (line 3517) **before** the early-return gate at lines 3503–3505
and lines 3510–3513, and **re-start** capture if the archive was finalized but activation is denied.

Specifically:

```cpp
void try_activate_deferred_mtp(server_slot & slot) {
    if (slot.mtp_prefill_mode != SLOT_MTP_PREFILL_DEFERRED ||
            slot.mtp_backfill_blocked || !slot.spec_cycle_idle()) {
        return;
    }

    // 1. Always finalize to bound the live capture (fixes unbounded growth)
    slot.finalize_mtp_archive();
    if (!slot.mtp_hidden_archive) {
        slot.mtp_prefill_mode = SLOT_MTP_PREFILL_TARGET_ONLY;
        return;
    }

    // 2. Check policy
    const size_t active_streams = ...;
    const uint32_t mtp_mask = 1u << COMMON_SPECULATIVE_TYPE_DRAFT_MTP;
    const uint32_t allowed = server_speculative_allowed_mask(
            active_streams, common_speculative_loaded_mask(spec.get()),
            speculative_policy_limits);
    if ((allowed & mtp_mask) == 0) {
        // DENIED: restart capture from finalized archive
        const auto info = common_speculative_hidden_archive_get_info(
                slot.mtp_hidden_archive);
        common_speculative_mtp_capture_begin(
                spec.get(), slot.id, next_mtp_archive_id++,
                info.pos_end + 1, slot.mtp_hidden_archive);
        slot.mtp_hidden_archive.reset();
        slot.mtp_capture_active = true;
        return;
    }

    // 3. Activation granted — backfill
    const auto result = common_speculative_mtp_backfill(
            spec.get(), slot.id, slot.mtp_hidden_archive);
    // ... (existing code)
}
```

### What this means for cost

| Component | Cost per activation attempt | Notes |
|-----------|---------------------------|-------|
| `finalize_mtp_archive()` | ~O(blocks) | Moves builder blocks into immutable archive — cheap, no copy of row data |
| `capture_begin()` with prefix | ~O(1) | Prefix is shared ownership — no copy |
| `need_embd_nextn` | Still forced? | **Yes**, `capture_active` will be `true` again, so NextN embeddings remain active |
| Memory bound | **Bounded** to `pos_max × n_embd × 4` at each finalize point | Archive grows between finalize calls, but not across calls |

### The `need_embd_nextn` residual

Even with this fix, `need_embd_nextn` returns true for all target-only steps because:
- After finalize + re-begin, `capture_active` is `true` again
- `need_embd_nextn` checks `capture_active(seq_id) || eligible`
- So `llama_set_embeddings_nextn(ctx_tgt, true, false)` persists

**UNVERIFIED**: Whether this causes a measurable per-step compute cost on non-CUDA backends. On
Vulkan/ROCm the embeddings are already in host-visible memory. On CUDA with `cudaHostAllocMapped`
it may also be free. The cost is only definitively present for CUDA configurations where the
KV cache is device-only and the NextN output must be copied. This needs a backend-specific
measurement.

---

## Control-Committed vs. Mechanical Decision

| Decision | Who owns it | Rationale |
|----------|-------------|-----------|
| Whether to finalize+re-begin on denial | **Control-committed** | This is a scheduling/policy decision — it determines whether the slot keeps trying to activate or gives up. |
| Whether `need_embd_nextn` should be gated on `eligible` not `capture_active` | **Control-committed** | This is an MTP-impl design choice. The current code forces NextN for any capture, but if capture is just passive recording, maybe NextN isn't needed for target-only rows. **UNVERIFIED**: whether target-only decode without NextN still produces correct pre-norm embeddings via post-norm + renormalize. |
| The finalize+re-begin mechanism itself | **Mechanical executor** | The archive builder already supports immutable finalize and prefix-based continuation. No new primitives needed. |
| Capping total live-archive memory across all slots | **Control-committed** | The implementation plan explicitly punts this to "server resource admission." No mechanical executor should guess a cap. |

---

## Open Questions

1. **Can `need_embd_nextn` skip `capture_active` slots during target-only decode?** If the capture
   only needs post-norm embeddings (via `llama_get_embeddings_ith`) and not pre-norm embeddings
   (via `llama_get_embeddings_nextn_ith`), then the `need_embd_nextn` gate could be narrowed to
   only `eligible` slots. **UNVERIFIED**: whether `llama_get_embeddings_nextn_ith` at
   speculative.cpp:1711 always reads pre-norm embeddings, and whether the capture needs pre-norm
   specifically.

2. **Is the repeated finalize+re-begin overhead acceptable?** In `pre_decode()`, activation is
   attempted every iteration with a single-token decode batch. Finalize moves blocks (O(blocks),
   no copy of data). Re-begin with prefix is O(1). The amortized cost is negligible compared to
   the decode itself.

3. **Should the activation check rate be throttled?** Currently called every decode step. Could be
   throttled to every N tokens or only when the active-stream count changes. This is a
   control-committed policy decision; the mechanical fix should not guess.

4. **What happens when max_tokens is large (e.g., 4096)?** With n_embd=4096, the unbounded capture
   would consume ~67 MiB of DRAM just for the generated-token archive. This is on top of the
   prompt-capture archive (which is typically much larger). The fix bounds this to the inter-attempt
   interval.

5. **Does the capture block overhead accumulate?** Each `process()` call with 1 token creates 1 new
   block. Each block has its own `shared_ptr`, `vector<token>`, and `vector<float>` allocations.
   With the fix, finalize consolidates the block list into an immutable archive, and re-begin starts
   a fresh builder. Over many attempts, this creates many immutable archives — but each replaces
   the previous, so only one archive + one builder exist at a time per slot.

