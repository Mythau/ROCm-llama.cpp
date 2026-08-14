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

## Archived experimental implementation inventory

This inventory is mined from local experimental commit `a7202a802`. It
describes the behavioural changes that were actually made, the mechanism each
change introduced and the impact it produced. The code is retained on branch
`experiment/deferred-mtp-prefill-spike`; it is not present on the production
`rocm-yolo` branch.

| Change made | Mechanism introduced | Impact and evidence |
|---|---|---|
| Added an explicit deferred-prefill start operation to the speculative implementation interface. | The server could announce the beginning of a prompt capture without knowing MTP's internal storage or reconstruction details. Implementations that did not support the experiment ignored the operation. | Confined the experiment to MTP while proving that the server/common boundary can initiate deferred work without putting MTP internals in the server. |
| Invoked deferred capture when a slot entered fresh prompt processing. | The MTP implementation received the logical sequence ID and expected prompt-token count before target prompt batches were decoded. | Established one capture lifetime for the request. It also exposed that the hook is too early for durable resident/cache-prefix reuse because `n_past` has not yet been finalized. |
| Restricted the experiment to one sequence, separate target/draft memory and a single MTP head. | Unsupported unified-memory, multi-slot and chained-head configurations remained on their ordinary path. | Kept the spike narrow enough to prove the computation without claiming mixed-batch or multi-head correctness. |
| Added one exact-size F32 DRAM archive for prompt tokens, logical positions and target hidden rows. | The implementation reserved `prompt_rows * n_embd` hidden values once, plus parallel token and position arrays. | Made the memory cost explicit and eliminated incremental vector growth: 8,192 rows at width 2,048 retained exactly 64 MiB; 10K rows would retain 78.125 MiB. |
| Added monotonically increasing archive identity and logical-span metadata. | Every capture recorded an archive ID, sequence ID, expected/captured rows, first/last logical positions, hidden width, storage type and capture start time. | Made logs and captured data attributable to one logical capture. The later audit established that the numeric ID is provenance, not durable ownership. |
| Reset the draft sequence before target-only capture began. | Existing draft KV was removed, `pending_h` was zeroed and MTP synchronization returned to unknown before any archived rows were accepted. | Prevented the deferred rebuild from inheriting an earlier request's MTP boundary or KV state. |
| Intercepted each completed target decode view while capture was active. | Instead of immediately processing the view through the MTP context, the implementation obtained the completed target NextN output and retained the view's tokens, positions and hidden rows. | Removed MTP draft-context computation from the target-prefill phase while keeping all inputs required to reconstruct it later. |
| Used one NextN retrieval and three contiguous bulk copies per completed target view. | Each view performed one synchronization/access to the reusable target output, then copied its token array, position array and contiguous hidden matrix into their final DRAM offsets. | Avoided per-row accessor/synchronization overhead. Three warm passes measured about 1.17% target-prefill loss versus target-only prefill. |
| Counted actual decoded rows rather than assuming every view was full sized. | Each view advanced the archive by its real `n_tokens`; the first and last logical positions came from the decoded view itself. | Correctly handled the final partial target region in the single-slot experiment and provided the evidence for the later scheduler-independent block contract. |
| Returned early from ordinary MTP processing while capture was active. | Captured target rows were not simultaneously uploaded into or decoded by the MTP context. | Isolated target NextN production plus DRAM retention from immediate MTP prefill. This produced warm target capture around 5,260 rows/s instead of the roughly 2,512 t/s client prefill observed with immediate MTP in the initial directional run. |
| Triggered reconstruction when speculative generation began after prompt completion. | MTP `begin()` detected the completed archive and flushed it before normal draft generation proceeded. | Proved that deferred reconstruction can be inserted between target prefill and the first MTP proposal. It was an experimental coupling, not the final on-demand activation design. |
| Inserted a fixed five-second diagnostic delay before reconstruction. | Capture completion and MTP backfill were separated visibly in timing and logs. | Allowed the two phases to be measured independently. The delay was excluded from phase results and is not a proposed runtime behaviour. |
| Rebatched archived logical rows using the draft context's own decode batch capacity. | Reconstruction iterated the archive in chunks independent of the target capture view sizes. | Demonstrated the important separation between target-capture geometry and MTP-backfill geometry, although the source archive was still one monolithic allocation. |
| Recreated the causal MTP input shift explicitly. | MTP position zero received the zero initial hidden row; logical position `k` received target hidden row `k - 1`. Tokens and positions came from the archive. | Reconstructed the same input relationship required by immediate MTP prefill rather than merely replaying same-position hidden rows. |
| Ran the ordinary draft-context decode over every reconstructed batch. | The normal MTP model populated its KV cache from the archived inputs. | Backfilled all 8,192 positions in a mean 124.3 ms across three warm measured passes, about 65,900 rows/s. |
| Installed the final archived target row as the next MTP boundary. | After successful KV reconstruction, the last retained target hidden row replaced `pending_h` and MTP synchronization became valid. | Allowed normal speculative decoding to start at the correct continuation boundary. |
| Preserved ordinary MTP proposal and acceptance after reconstruction. | Once synchronization was published, the experiment returned to the existing MTP draft/verify/accept path rather than adding an experimental decoder. | Three measured passes generated 430-449 draft tokens and accepted 360-367 while completing exactly 512 requested output tokens with hard integrity checks passing. |
| Timed target capture and MTP reconstruction separately and logged archive size/coverage. | Capture duration began at reservation; backfill had an independent timer; the diagnostic delay was outside both. | Distinguished the roughly 1% target-prefill capture cost from the roughly 124 ms reconstruction cost and prevented TTFT from being mislabeled as target-prefill throughput. |
| Released the monolithic archive after successful reconstruction. | Token, position and hidden vectors were cleared and their capacities returned after equivalent synchronized MTP state existed. | Proved the archive need not remain resident once live MTP KV is available, but also prevented the spike from testing prompt-cache ownership or later retry. |
| Invalidated MTP if a reconstruction decode failed. | A failed draft-context batch aborted reconstruction and marked the MTP sequence unusable. | Prevented partially reconstructed draft KV from being treated as synchronized. The durable design still needs transactional cleanup while retaining a valid immutable archive for retry. |
| Returned an opaque `{archive ID, sequence ID}` handle to the owning server slot and cleared it with the prompt. | The slot retained capture provenance without gaining access to MTP archive contents. | Proved the identification boundary, then showed why an actual shared archive reference should replace the numeric slot handle when RAM-cache ownership is implemented. |

### What the archived spike proved

- Target hidden-row retention and MTP KV construction can be separated in time.
- Immediate MTP processing is not required during target prefill.
- The retained row mapping is sufficient to reconstruct usable MTP KV and its
  continuation boundary.
- Warm NextN retention cost was small relative to immediate MTP prefill.
- MTP reconstruction cost was small enough to make on-demand activation
  credible without moving it to another GPU or CPU as a prerequisite.
- Capture view sizes and MTP backfill batch sizes can differ.

### What it deliberately did not prove

- Multiple sequences or mixed server batches.
- Resident or RAM prompt-cache reuse.
- Prefix slicing, strict extension or decode-tail capture.
- On-demand activation after target-only decode has advanced.
- Shared archive ownership, eviction or retry after failed backfill.
- Asynchronous staging or removal of the remaining capture-time memcpy.
- Context shift, non-contiguous remapping or multi-completion cloning.

## Durable implementation mechanisms

The durable implementation should consist of five owned mechanisms. These are
implementation boundaries, not invitations to create five frameworks.

| Mechanism | Responsibility |
|---|---|
| Hidden archive | Own immutable logical-position blocks and provide sequential row access independent of capture and backfill batch sizes. |
| MTP capture and backfill | Capture target rows when deferred, finalize the archive, reconstruct draft KV on demand, install `pending_h` and publish synchronized MTP state. |
| RAM prompt-cache payload | Retain one shared archive reference as an alternative to synchronized draft/spec state, include its bytes in existing limits and transfer it without copying. |
| Server selection | Enable the capability at server startup and select immediate MTP, deferred MTP or target-only for each request using existing eligibility/policy state. |
| Target-state lifecycle | Drop or retain the archive at the same existing prompt-clear, prefix-reuse, slot-reuse and target-KV mutation boundaries that determine whether its logical coverage is still valid. |

These five durable mechanisms are now implemented on the production branch.
The archive is block-based and immutable after publication; deferred capture
partitions completed target views by sequence; explicit backfill reconstructs
draft KV using its own batch geometry; the RAM prompt cache retains the same
archive reference and charges its bytes; and the server integrates selection,
prefix reuse, activation and target-lineage invalidation. CPU archive and server
compile regressions pass. Model-backed mixed-slot isolation, decode-tail
activation, RAM-cache restore, lineage mutation, cancellation/replay and
backfill success have also been exercised. The remaining performance work is
optimization and backend profiling rather than a missing correctness mechanism.

The first durable version remains synchronous and deliberately excludes:

- Background copy workers and rotating output-buffer leases.
- Preservation across context shift or non-contiguous remapping.
- Generic multi-completion archive cloning.
- Moving MTP backfill to another GPU or the CPU.
- A new archive manager, registry, scheduler framework or compatibility layer.

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

### Speculative payload contract

Deferred MTP does not introduce another manager. `common_speculative` remains
the authority for per-sequence speculative state. The server owns the logical
target-KV lifecycle, the draft context owns live MTP KV, and the prompt cache
stores one opaque speculative payload beside the serialized target state.

```text
TARGET_ONLY

SYNCHRONIZED_MTP
    + serialized draft KV
    + speculative boundary blob

DEFERRED_ARCHIVE
    + shared immutable hidden-archive reference
```

These representations are exclusive. Synchronized MTP state normally releases
the live archive; a deferred archive means MTP KV is not synchronized; target
only contains neither optional representation.

The common-layer cache contract is conceptually:

```text
capture_payload(sequence)
    -> target-only, synchronized-MTP, or deferred-archive

restore_payload(sequence, payload)
clear_payload(sequence)
```

The server always captures/restores target state first. It captures/restores
draft KV only for `SYNCHRONIZED_MTP`, attaches an archive only for
`DEFERRED_ARCHIVE`, and otherwise retains a target-only state.

Ownership is one-way: live sequence, cache entry and temporary synchronous
backfill may reference the archive, but the archive never references any of
them. There is no archive lookup registry, second cache, callback network or
new server-wide archive manager.

### Single representation decision

The representation branch is real and unavoidable, but it belongs in one
speculative cache-capture/apply contract rather than being repeated in cache
allocation, scheduler code and microbatch capture.

Deferred MTP is an explicit server-startup capability, analogous to a loaded
speculative implementation. Loading an MTP model does not implicitly enable
hidden-row capture. A separate per-sequence state then records whether the
loaded capability is selected for that request, analogous to speculative
eligibility. With the startup capability absent, none of the deferred capture,
archive or backfill path is entered and existing MTP behaviour remains exact.

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

## Implementation plan

The authoritative task sequence is maintained in
`MTP_DEFERRED_PREFILL_IMPLEMENTATION_PLAN.md`.

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

### Timing attribution

The server prompt timer begins when a slot enters prompt processing and is
finalized when sampling synchronizes the first generated token. Immediate MTP
processing runs after each target decode view and before that first sample, so
it is included in `timings.prompt_ms`.

Deferred activation has two timing cases:

- If demand permits activation when the prompt reaches `DONE_PROMPT`, backfill
  runs before the first sample and is included in `timings.prompt_ms`.
- If the request has already begun target-only generation, the prompt timer is
  already finalized. A later on-demand backfill is not prompt work according to
  that metric and must be reported separately.

Therefore a reported prompt rate is not sufficient to compare every deferred
activation. The durable reporting contract is target capture time, backfill
time and activation position, with TTFT reported separately when backfill
precedes the first token.

The later single-slot `mtp-deferred-cohort` does not compare immediate and
deferred execution. With one active slot and no constraining active-limit map,
both configurations selected immediate MTP; the near-identical 4,993.4 and
4,994.3 t/s means only that enabling the deferred capability has no measurable
cost when it is not selected.

The phase-isolated experiment remains the applicable evidence: warm target
capture plus its 64 MiB retained copy took 1.557 seconds on average, and MTP
backfill took another 124.3 ms. Those timers measure actual work rather than
relabeling TTFT. The diagnostic five-second separator was outside the recorded
phase timings and the recorded server prompt timing.

There is not yet controlled evidence that deferred MTP performs less total MTP
computation than immediate MTP. Instrumented immediate views were already large
logical batches and each caused one draft-context decode. The observed
separation benefit can come from removing draft work from the target-prefill
critical path and from executing reconstruction contiguously, but attributing
the remaining difference to graph switching, synchronization or backend launch
cost requires ROCm profiling.
