# Deferred MTP prefill experiment

This is an intentionally narrow experiment. It is not the final cache or
scheduler design.

## Immediate checklist

- [x] Restrict the experiment to one fresh server slot and one complete prompt.
- [x] Allocate one exact-size host buffer for every target `h_nextn` prompt row.
- [x] Make the retained rows an identified archive carrying a capture ID,
  logical sequence ID, position range, row count, hidden width and storage type.
- [x] Return an opaque `{capture ID, sequence ID}` handle to the server slot that
  owns the corresponding logical prompt/KV lineage. The current experiment
  keeps it as provenance after backfill consumes the rows; later cache work must
  replace that with owned archive storage before the handle can retrieve data.
- [x] Capture prompt token, position and `h_nextn` rows while target prefill runs.
- [x] Drain each completed target batch view into the DRAM archive with one
  synchronization and contiguous bulk copies rather than per-row accessors.
- [x] Do not run the MTP draft context during target prefill.
- [x] At prompt completion, backfill the MTP context in ordered batches using:
  - position zero: the zero initial hidden row;
  - position `k`: target `h_nextn[k - 1]`.
- [x] Populate the MTP KV cache through the final prompt position.
- [x] Install the final target hidden row as `pending_h` and mark MTP synchronized.
- [x] Run ordinary MTP speculation and prove that it generates and accepts drafts.
- [x] Record target-prefill time, MTP-backfill time, retained-host-buffer size and
  decode throughput separately.
- [ ] Compare the first MTP draft and acceptance behaviour with immediate MTP.

## Deliberately excluded from this experiment

- Prompt append or partial-prefix capture.
- Resident or RAM prompt-cache restoration.
- Multiple slots or mixed target batches.
- Context shifting, rewind, cancellation recovery or late MTP activation.
- Persistent hidden-row storage after MTP backfill.
- Cleanup into a production-quality public interface.

## Durable archive block contract

This contract governs the later cache-owned archive. The current monolithic
single-slot vector is only an experiment and must not become the persistent
data model.

An archive block represents one completed target NextN output region, not one
configured batch or microbatch. Every block stores its actual logical span:

```text
sequence_id
pos_first
row_count
```

`row_count` must never be inferred from `n_batch` or `n_ubatch`. Archive
identity and validity are defined by logical sequence positions, not raw server
batch indexes. Consecutive blocks in one archive must describe one contiguous
logical history:

```text
next.pos_first == previous.pos_first + previous.row_count
```

Mixed server batches must be partitioned by sequence before publication. Rows
from different slots must not enter the same logical archive block. Explicit
per-row ownership is deliberately excluded unless a later requirement proves
that complexity necessary.

The active capture builder may be mutable. A block becomes immutable when it
is published; cache entries and MTP backfill jobs receive only finalized
immutable blocks. Dynamic batch or microbatch changes affect only future
blocks. Existing blocks are never resized, merged, rewritten or invalidated
merely because scheduler geometry changes.

Prefix slicing retains block references and represents the boundary block with
an `{offset, count}` slice. It must not copy the retained prefix into a new
monolithic allocation. Strict extension appends newly finalized blocks to the
existing archive without repacking old blocks.

MTP backfill consumes a logical row iterator spanning arbitrary archive-block
boundaries. It chooses its own decode batch size and must not assume archive
blocks match that size:

```text
archive block boundaries != MTP backfill batch boundaries
```

Staging-buffer capacity is also independent of logical block size. A leased
staging buffer records its actual valid row count, and a final partial region is
normal. Cache accounting uses the allocation's retained bytes, not
`block_count * current_ubatch_size`.

An archive is usable only when its logical position coverage exactly matches
the retained target-KV prefix. The first durable implementation invalidates it
on context shifting or any non-contiguous remapping.

Configured batch and microbatch sizes are not archive compatibility fields.
They may be retained as diagnostic metadata, but changing either value must not
invalidate an archive.

The governing rule is:

> Never make scheduler batch geometry part of the archive's persistent data
> model. Store actual completed logical row spans and let capture, staging and
> backfill use independent chunk sizes.

## Prompt-cache ownership audit

The existing RAM prompt cache is the correct durable owner for a completed
deferred-MTP archive. It already owns the logical prompt and target-KV snapshot,
selects entries by cache key and retained prefix, accounts retained bytes,
evicts old entries and transfers a selected entry through `take()` and
`apply()`. A separate hidden-state cache, registry or eviction policy would
duplicate that authority.

The current prompt-cache transaction is:

1. `server_slot::prompt_save()` decides which optional speculative state is
   valid, obtains the serialized target/draft sizes and captures the small
   speculative boundary blob.
2. `server_prompt_cache::alloc()` checks cache limits, removes obsolete entries,
   evicts old entries and allocates the target/draft byte vectors.
3. `prompt_save()` serializes the complete target state and, when synchronized,
   the complete draft state.
4. `take()` moves the selected cache entry out of the LRU list without copying
   its stored vectors.
5. `apply()` restores target state first, then restores or clears optional
   speculative state.

The deferred archive should become one additional opaque payload on
`server_prompt_data`. The cache stores and transfers a shared reference to the
already allocated archive; `alloc()` must not allocate, clone or copy its hidden
rows. Its retained allocation size is included in the existing cache limit and
eviction accounting.

The stable cache representations are mutually exclusive:

| Representation | Target state | Draft state | Spec blob | Hidden archive |
|---|---:|---:|---:|---:|
| Target only | yes | no | no | no |
| Synchronized MTP | yes | yes | yes | no |
| Deferred MTP | yes | no | no | yes |

Once synchronized MTP state has been produced, the hidden archive is normally
released rather than retaining both representations.

### Ownership

```text
mutable capture builder in common/speculative
    -> finalized shared immutable archive
         -> live speculative sequence
         -> RAM prompt-cache entry
         -> temporary MTP backfill transaction
```

The numeric archive ID is diagnostic provenance only. It is not an ownership
registry. Once the shared archive-reference path exists, the temporary numeric
handle stored by `server_slot` is no longer required.

Shared ownership is justified because `prompt_save()` snapshots an otherwise
still-resident slot: the live sequence and RAM cache may legitimately reference
the same immutable archive, and a backfill transaction must keep it alive while
it runs. Cache eviction drops only the cache reference; physical storage is
released when the final owner releases it.

### Single representation decision

The representation branch is real and unavoidable, but it belongs in one
speculative cache-capture/apply contract rather than being repeated in cache
allocation, scheduler code and microbatch capture.

Common speculative code should return one of:

```text
TARGET_ONLY
SYNCHRONIZED  + speculative boundary blob
DEFERRED      + hidden archive reference
```

`prompt_save()` switches once:

- `SYNCHRONIZED`: serialize draft state and store the speculative blob.
- `DEFERRED`: attach the archive reference and serialize no draft state.
- `TARGET_ONLY`: store neither optional representation.

After successful target restoration, `apply()` switches once:

- attach a deferred archive to the speculative sequence; or
- use the existing synchronized draft/spec restore path; or
- retain the target hit with no speculative state.

The cache does not interpret MTP rows or readiness. Apart from byte accounting,
it remains an opaque storage and transfer mechanism. The old monolithic
`server_prompt_cache::load()` path must not gain a second copy of this policy;
the durable path is `take()` plus `apply()`.

### Cache ownership does not remove capture-time copying

Prompt-cache attachment eliminates any archive-to-cache copy. It does not
eliminate the copy required while target NextN output is captured:

```text
GPU target h_nextn
    -> llama_context reusable device-host output buffer
    -> persistent ordinary-DRAM archive block
```

The backend asynchronously transfers `t_h_nextn` into llama-context's reusable
host output buffer. `llama_get_embeddings_nextn()` synchronizes and exposes
that buffer, but the next target decode may overwrite it. Each completed region
therefore has to acquire durable storage before the next reuse.

The normal whole-state serializer cannot replace this operation because
`h_nextn` is not persistent target KV state. Similarly, adding two buffers only
inside `common/speculative.cpp` would create an additional copy:

```text
GPU -> existing pinned output -> speculative staging -> final archive
```

If the measured capture penalty warrants optimization, the rightful boundary
is llama-context's NextN output destination: make the existing destination a
leaseable rotating pair/ring, or allow async extraction to write directly into
a leased staging destination. After completion, a worker copies the leased
valid rows into an ordinary-DRAM immutable archive block and returns the lease.
This is separate from prompt-cache ownership.

### Capture and restore rules

The durable capture hook must run after `n_past`, resident-prefix reuse and
target-KV mutations have been resolved. The current experimental hook runs too
early and assumes an entirely fresh prompt.

For a selected target cache entry:

- An exact retained prefix may reuse the corresponding archive coverage.
- Strict extension retains old block references and appends new blocks.
- A shorter but contiguous retained prefix uses block references plus one
  boundary `{offset, count}` slice, without copying the prefix.
- A suffix without complete archive coverage for the retained target prefix is
  not independently useful and must not be published as a complete archive.
- Context shifting and non-contiguous chunk remapping invalidate the archive in
  the first durable implementation.
- Target cache selection remains authoritative; an inferior target match is
  never preferred merely because it carries hidden rows.

If MTP remains deferred after prompt evaluation, ordinary target decode moves
the target-KV boundary forward. The archive must append the generated-token
NextN rows as well; a prompt-only archive cannot later reconstruct MTP at the
current target position.

Backfill reads the logical row iterator, constructs draft KV transactionally
and holds an archive reference until completion. Success publishes synchronized
MTP state and releases the archive. Failure clears partial draft state while
retaining the immutable archive for retry unless the failure proves its target
boundary invalid.

Lifecycle transitions are direct consequences of existing target-state
mutations:

- `prompt_clear()` or slot destruction drops the live archive reference.
- Cache eviction drops the cache reference.
- Slot reuse drops the previous sequence reference before applying another
  cache entry.
- Capture cancellation discards the unpublished mutable builder.
- Context shift or non-contiguous remapping discards the archive.
- A future background capture worker publishes only when its capture ID still
  belongs to the intended logical sequence generation.

The RAM-cache list remains server-thread-owned. Background workers may own a
builder, immutable archive/block reference or staging-buffer lease, but never a
raw `server_slot *` and never the cache container itself.

## Durable implementation checklist

1. Replace the nested experimental vector with an opaque common-layer archive
   object using immutable logical-span blocks and sequential row iteration.
2. Separate mutable capture, archive finalization and explicit MTP backfill;
   remove automatic backfill as a side effect of capture completion.
3. Move capture preparation after retained target-prefix resolution, implement
   reference-based prefix slicing/extension and append target-only decode rows.
4. Add the shared opaque archive reference to `server_prompt_data`, include its
   retained bytes in cache accounting and transfer it without copying through
   `alloc()`, `take()` and `apply()`.
5. Route prompt clearing, slot reuse, context shifting, chunk remapping and
   failed backfill through the direct archive lifecycle transitions above.
6. Add CPU-only tests for block append/finalize/slice, iterator order across
   block boundaries, no-copy cache identity transfer, byte accounting, LRU
   lifetime and the three valid cache representations.
7. Instrument the existing NextN output-buffer lifetime before deciding whether
   a leaseable rotating output ring is worth implementing for the measured
   capture-time cost.

## Later challenges

- Instrument the target microbatch/output path to identify the exact point at
  which each `h_nextn` region is complete and safe for a background consumer.
- Evaluate double-buffered host staging for `h_nextn`: while the target fills
  one bounded buffer, a dedicated worker copies the other completed buffer into
  the prompt-sized ordinary-DRAM archive. Swap ownership when a buffer fills,
  preserve row order, flush the final partial buffer at prompt completion, and
  apply backpressure only if the copy worker falls behind.
- Compare the double-buffered path against the current synchronous bulk copy.
  Determine whether it removes the measured 1.17% target-prefill penalty without
  introducing an earlier GPU synchronization, excessive pinned memory, or CPU
  memory-bandwidth contention. Keep the archive in ordinary DRAM; only the two
  bounded staging buffers may need backend-pinned host memory.
- Evaluate MTP backfill on a different GPU from the target prefill.
- Evaluate MTP backfill on the CPU. The MTP head is small relative to the target
  model, so avoiding GPU scheduling and transfer contention may outweigh lower
  raw CPU throughput. Measure it; do not assume it.
- Evaluate chunked GPU/CPU pipelining while target prefill is still producing
  hidden rows.
- Evaluate beginning non-speculative decode while deferred MTP catches up, then
  activating MTP only at a proven synchronized boundary.
- Replace the experimental single-slot storage with an owned, versioned prompt
  state suitable for cache save/restore.

At `n_embd = 2048`, retained float32 target rows cost exactly 8 KiB per token:
78.125 MiB at 10K tokens and 781.25 MiB at 100K tokens.

## First experimental result

Qwen3.6 35B-A3B Q8_0, one fresh slot, partitioned BF16 KV, batch 8,192 /
microbatch 1,024, 8,192 prompt tokens and 512 generated tokens:

| Path | Client prefill / TTFT rate | TTFT | Decode |
|---|---:|---:|---:|
| Immediate MTP | 2,511.8 t/s | 3.261 s | 111.30 t/s |
| Deferred MTP | 3,483.9 t/s | 2.351 s | 115.17 t/s |
| Deferred MTP, warm repeat | 3,484.3 t/s | 2.351 s | 111.58 t/s |

The deferred path allocated 64.000 MiB for 8,192 hidden rows and backfilled the
complete MTP KV in 135.8 ms. Normal MTP generation then produced 441 draft
tokens and accepted 364 (82.5%). Both requests passed the hard output-integrity
checks.

This is a directional experiment, not a publishable A/B result. The binaries
have different build identities embedded in the synthetic prompt, and each
path does not yet have a controlled repeated cohort. One deferred run launched
after a long compile idle period captured the target rows much more slowly,
showing that GPU warm/clock state must be controlled. The two warm deferred
runs captured all 8,192 rows in about 2.21 seconds and backfilled MTP in 135.8
and 136.8 ms. Exact same-prompt/seed comparison and controlled repetition remain
outstanding.

## Warm-state cost isolation

The apparent heavy target-prefill regression was primarily a cold GPU clock
artifact. A single cold/reference wave is not a valid comparison on this host.
After one discarded full-prompt warmup, the no-spec target prompt evaluation
settled at about 1.54 seconds for 8,192 tokens.

The experiment was then split into independently timed phases, erasing the
single slot between waves so every measured request began from an empty KV
state:

| Phase | Warm 8,192-token time | Finding |
|---|---:|---|
| Target without speculation | about 1.54 s | Baseline target work |
| Target NextN output, no retained copy | about 1.54 s | No measurable steady-state penalty |
| Target NextN output plus exact 64 MiB retained bulk copy | 1.557 s mean (1.554–1.560 s) | 5,260 t/s; 1.17% below the 5,322 t/s no-spec baseline |
| Deferred MTP KV backfill | 124.3 ms mean (122.7–125.7 ms) | About 65,900 prompt rows/s |

The three measured passes used fresh erased slot state and all completed exactly
512 generated tokens with hard output-integrity checks passing. Target capture
plus synchronous MTP backfill averaged 1.682 seconds, equivalent to 4,871
prompt rows/s. This is 8.47% below the no-spec target-prefill rate, but it is a
combined pre-generation preparation rate rather than target prefill itself.

For phase separation, the current experiment waits exactly five seconds after
capture and before MTP backfill. That known delay is excluded from every phase
number above; client TTFT and the server's combined prompt timer include it and
must not be reported as prefill throughput.

The result is useful but still experimental: the retained host copy is cheap,
NextN production is effectively free once warm, and the roughly 124 ms MTP
backfill is the main remaining synchronous cost. The five-second delay is a
diagnostic separator, not a proposed production behaviour.
