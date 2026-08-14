# Deferred MTP prefill implementation plan

This plan turns the proven single-slot spike into a durable extension of the
existing dynamic-speculation and RAM prompt-cache mechanisms. The design and
experimental evidence remain in `MTP_DEFERRED_PREFILL_EXPERIMENT.md`.

The inventory describes evidence; it does not prescribe one class, API or task
per item. The implementation has five owners: archive storage, MTP
capture/backfill, prompt-cache payload, server selection and target-state
lifecycle.

## Version-one behaviour

- Deferred MTP is disabled unless explicitly enabled at server startup.
- When disabled, existing MTP and dynamic-speculation behaviour is unchanged.
- A request selected for immediate MTP builds draft KV normally and creates no
  hidden archive.
- A request selected for deferred MTP captures target hidden rows but performs
  no MTP draft-context prefill until selected for activation.
- A deferred archive follows the logical target-KV state into and out of the
  existing RAM prompt cache without copying its retained rows.
- Deferred MTP may activate only at an idle speculative-cycle boundary when the
  archive covers the complete current target-KV history and current demand
  permits MTP.
- Context shifting or non-contiguous target-history remapping discards the
  archive in version one.
- Capture remains synchronous initially. Output-buffer leasing and background
  copying are performance work, not prerequisites for correctness.

## Authority

| Owner | Sole responsibility |
|---|---|
| Hidden archive | Immutable logical-position blocks, retained-byte accounting, prefix views and sequential row iteration. |
| MTP implementation | Mutable capture, view partitioning, archive finalization, draft-KV backfill, `pending_h` and MTP synchronization. |
| RAM prompt cache | Opaque archive-reference storage, byte limits, eviction and transfer with the selected target state. |
| Server selection | Startup capability, per-request immediate/deferred/target-only choice and the safe activation decision. |
| Target-state lifecycle | Calls archive retain/slice/drop operations at existing prompt/KV mutation boundaries. |

The cache does not interpret hidden rows. The server does not construct MTP KV.
MTP does not select cache entries or scheduling policy. No archive registry or
second cache is introduced.

`common_speculative` remains the per-sequence manager. Its cache boundary
returns one discriminated payload: target-only, synchronized MTP plus boundary
blob, or deferred archive reference. Server save/apply uses that result to
decide whether draft KV bytes accompany the always-captured target state. No
independent archive manager or duplicated public state machine is added.

## Placement and impact on existing mechanisms

### Hidden archive and RAM limits

The archive data model belongs to common speculative code because MTP creates
and consumes its rows. The archive is never a free-standing server allocation:
it is an optional payload of one exact logical target-KV lineage.

The ownership invariant is:

```text
live target prompt/KV state
    -> target-only, synchronized MTP, or deferred archive

cached target prompt/KV state
    -> target-only, serialized synchronized MTP, or deferred archive
```

The target state and its optional archive are cleared, transferred and restored
as one logical transaction. Clearing or remapping target KV drops the archive
reference before the target mutation. Saving target state attaches the archive
to the same cache record. Taking and applying that record attaches the archive
to the restored target lineage.

While a request is live, its archive is live request memory and is not part of
the RAM prompt-cache limit, just as live target/draft contexts are not counted
as cached entries. It remains owned by the live target prompt/KV state rather
than by an independent archive container.

When a finalized archive reference is attached to a RAM prompt-cache entry, its
full retained allocation is included in that entry's existing size/eviction
accounting. The cache may retain and move the opaque reference and query its
retained byte count; it does not access hidden rows or decide whether they are
valid for MTP.

Shared live/cache ownership does not duplicate the allocation. If immutable
blocks are ever shared by multiple cache entries, charging their full retained
bytes to each entry conservatively overestimates usage but does not exceed the
configured cache limit through under-accounting.

A temporary synchronous backfill operation may hold another reference, but it
does not become an independent durable owner. On success, synchronized MTP
state replaces the live archive representation. On failure, the archive remains
with the still-valid target lineage. Version one has no background job that can
outlive that lineage.

The prompt-cache limit remains a cache limit rather than a total process-memory
limit. If a total live-archive cap is later required, it belongs to server
resource admission and must not be hidden inside archive validity or cache LRU
logic.

### Deferred target capture

Capture storage and row interpretation belong to MTP. The server supplies only
the selected mode and the resolved retained target boundary.

Capture starts after resident/cache prefix resolution has finalized `n_past`,
not merely when a slot first enters prompt processing. Each completed target
decode view is then offered to common speculation. MTP partitions its rows by
logical sequence and publishes blocks identified by capture generation,
sequence ID, first logical position and actual contiguous row count.

Raw server batch indexes, configured batch size and configured microbatch size
are never archive identity. Dynamic scheduler geometry therefore changes only
the sizes of future completed regions.

### Explicit MTP backfill

Backfill belongs entirely to the MTP implementation. It consumes the archive's
logical iterator, chooses its own draft decode batches, reconstructs draft KV,
installs the continuation boundary and publishes synchronization. The server
only requests activation at a safe boundary and receives success or failure.

The spike already proved the row mapping and ordinary MTP decode path. Durable
work is principally the explicit transaction, arbitrary-block iterator and
retry-preserving failure behaviour.

### RAM prompt-cache payload

Do not begin with another bulk transfer. The spike already copied the reusable
NextN output into durable DRAM. Copying that archive again during prompt save
would temporarily double potentially hundreds of MiB and would test the wrong
boundary.

The first durable cache implementation attaches the finalized shared archive
reference directly. Existing whole target/draft state serialization remains
unchanged because hidden rows are not part of llama KV state. The only cache
changes are the optional opaque payload, retained-byte accounting and the
single target-only/synchronized/deferred representation decision around save
and apply.

### Server lifecycle

The relevant existing lifecycle is:

```text
admission and optional RAM-cache target restore
  -> STARTED
  -> resolve resident/checkpoint prefix and final n_past
  -> PROCESSING_PROMPT
  -> target decode view(s) and speculative process callback
  -> DONE_PROMPT
  -> GENERATING and speculative begin
  -> target decode/verification cycles
  -> release to IDLE while retaining ordinary prompt/KV state
  -> later prompt save, reuse or prompt clear
```

Deferred integration follows those existing transitions:

- Admission/cache restore attaches an archive reference but does not interpret
  or backfill it.
- Final `n_past` resolution chooses exact reuse, prefix view or fresh capture.
- Each completed target decode view appends the rows for deferred sequences.
- Prompt completion finalizes prompt coverage; it does not automatically force
  backfill unless selection permits activation.
- Target-only generation continues appending rows while MTP remains deferred.
- A safe idle speculative-cycle boundary may invoke explicit backfill when
  current demand permits MTP.
- Normal `release()` retains the archive with the resident prompt/KV state.
- Prompt save shares it with the RAM cache before unified-KV idle clearing.
- `prompt_clear()`, context shift, non-contiguous chunk reuse and incompatible
  slot reuse drop it before mutating the corresponding target history.
- Cancellation during mutable capture discards the unpublished builder; a
  finalized immutable archive follows the retained target state.

The current occupancy planner demotes on admission and does not generally
promote survivors. Deferred activation is therefore a narrowly defined new
transition for a complete archive at an idle cycle, not permission to build a
general live-promotion scheduler.

## Dependency order

```text
DP-01 archive core
  -> DP-02 capture
  -> DP-03 backfill
  -> DP-04 prompt-cache payload
  -> DP-05 server selection
  -> DP-06 lifecycle integration
  -> DP-07 production validation
```

DP-04 can begin after DP-01 while DP-02/03 are being reviewed, but DP-06 is the
first task that connects all mechanisms.

| Task | Status |
|---|---|
| DP-01 logical hidden archive | Complete |
| DP-02 deferred target capture | Complete |
| DP-03 explicit MTP backfill | Complete |
| DP-04 RAM prompt-cache payload | Complete |
| DP-05 startup capability and selection | Complete |
| DP-06 server lifecycle integration | Complete |
| DP-07 validation and documentation | In progress |

## DP-01 - logical hidden archive

Create one opaque common-layer archive reference containing immutable blocks.
Each block records actual `{sequence_id, pos_first, row_count}` coverage and its
tokens and F32 hidden rows. Logical positions are derived from that contiguous
span. Scheduler batch sizes are not persistent compatibility fields.

Provide only the operations required downstream:

- mutable append builder followed by immutable finalization;
- retained-byte accounting;
- exact coverage query;
- prefix view using block references plus one boundary slice;
- sequential row iteration across arbitrary block boundaries.

Tests are CPU-only: append/finalize, final partial block, continuity, prefix
view without row copying, iterator order and retained-byte accounting.

Review focus: immutable publication, logical positions rather than raw batch
indexes, and no server/cache/MTP policy dependencies.

Implemented and checked with a CPU-only archive test covering a partial final
block, cross-block iteration, shared prefix slicing, strict extension and
retained-byte reporting. The common and server compile surfaces pass.

## DP-02 - deferred target capture

Move the spike's proven capture mechanism behind the archive builder.

- Begin capture only after the server has resolved the retained target prefix
  and supplies that boundary.
- Partition mixed decoded views by logical sequence before appending blocks.
- Store actual completed row spans; never assume a full microbatch.
- Continue appending target-only decode rows while MTP remains deferred.
- Do not capture when immediate MTP is already processing the same rows.
- Keep the existing synchronous bulk copy for version one.

The caller supplies immediate/deferred/target-only selection; capture does not
make policy decisions.

Version one uses the proven separate-target/draft, single-MTP-head path. The
later startup capability gate will reject deferred mode for shared-memory or
chained-head MTP rather than silently selecting this mechanism.

Review focus: one authoritative copy of each row, correct per-sequence ordering,
and no dependence on configured batch geometry.

Implemented in the MTP process boundary. Active captures request exact-view
NextN rows, partition grouped mixed views by sequence, append their actual
logical spans and exclude those sequences from immediate draft-context work.
Speculative verification is classified explicitly by server cycle state per
sequence; MTP no longer guesses from target row count or logits flags. CPU
compile/regression surfaces pass; model-backed execution remains in DP-07.

## DP-03 - explicit MTP backfill

Turn the spike's reconstruction into an explicit operation over the archive row
iterator.

- Use the draft context's own batch capacity independently of archive blocks.
- Feed position zero with the zero initial row and position `k` with target row
  `k - 1`.
- Construct draft KV through the ordinary MTP decode path.
- Install the final target row as `pending_h`.
- Publish synchronized MTP only after every batch succeeds.
- On failure, clear partial draft state and retain the valid immutable archive
  for retry.
- On success, release the live archive when no cache/backfill owner needs it.

Review focus: target/archive/draft position equality at commit, no partially
synchronized state and no server/cache knowledge.

Implemented as an explicit MTP operation over the archive row iterator. It
clears and reconstructs only the selected draft sequence using the draft
context batch capacity, installs the final hidden row as `pending_h`, and marks
the sequence synchronized only after exact target/archive/draft position
agreement. Decode failure removes partial draft KV and leaves the caller-owned
archive unchanged. CPU compile/regression surfaces pass; model-backed execution
remains in DP-07.

## DP-04 - RAM prompt-cache payload

Extend the existing prompt-cache record with one opaque shared archive
reference and consume the single common speculative payload contract.

- Stable cache payloads are target-only, synchronized draft/spec, or deferred
  archive; normally never both optional representations.
- Include archive retained bytes in existing cache limit and eviction
  accounting.
- Attach the already allocated archive reference without allocating or copying
  hidden rows.
- Preserve object identity through cache save, `take()` and `apply()`.
- Restore target state first. Optional failure must not destroy a valid target
  hit.
- Keep representation selection outside cache allocation and avoid adding the
  policy to the old monolithic cache-load path.

Tests are CPU-only where possible: payload combinations, byte accounting,
zero-copy identity transfer, eviction lifetime and target-only fallback.

Review focus: cache remains opaque storage, one representation branch and no
duplicate ownership registry.

Implemented as one opaque shared reference on `server_prompt_data`. Cache byte
accounting includes the archive's retained allocation; `alloc()`, `take()` and
the archive restore mode preserve object identity without copying hidden rows.
Target restore remains the partial-commit point, and a missing optional archive
returns a target-only result. The cache makes no scheduling or backfill
decision. Server compile surfaces pass; integrated restore execution remains in
DP-06/07.

## DP-05 - startup capability and selection

Add one server-startup option enabling deferred MTP. Exact CLI spelling is
chosen during implementation alongside existing speculative options.

Maintain separate facts:

- deferred capability loaded for this server;
- immediate/deferred/target-only selection for each logical request;
- MTP synchronized/eligible state already owned by common speculation.

Selection semantics:

- capability absent: preserve existing behaviour exactly;
- MTP currently selected for immediate execution: no archive;
- MTP loaded but deliberately deferred: capture/retain archive;
- no usable MTP or deferred capability: target-only;
- a deferred request becomes an activation candidate only when current demand
  permits MTP and its speculative cycle is idle.

Review focus: no duplicated eligibility state, no client override and no generic
promotion framework beyond the deferred-ready transition.

Implemented as the server-only `--spec-mtp-deferred` capability. It defaults
off and is accepted only when the actually loaded MTP implementation uses the
proven separate-memory, single-head mechanism. Immediate/deferred/target-only
remain ephemeral admission outcomes derived from the existing eligibility
plan; no client override or second mask was added. CLI/help, common and server
compile surfaces pass.

## DP-06 - server lifecycle integration

Connect the mechanisms at existing request and target-KV transitions.

- After retained-prefix resolution, select reuse, slice or fresh capture.
- Save and restore the archive through the RAM prompt-cache payload.
- Append prompt suffix and subsequent target-only decode rows.
- Invoke backfill at the selected safe activation boundary.
- Drop the archive on prompt clear, incompatible slot reuse, context shift or
  non-contiguous remapping.
- Retain exact or strict-prefix coverage without repacking old blocks.
- Preserve current target-first fallback when archive or MTP activation is not
  usable.

Review focus: target-KV mutation occurs only after any active speculative cycle
is resolved, cache policy is not duplicated, and every archive transition has
one owner.

Implemented at the existing admission, retained-prefix, decode, release and
prompt-cache boundaries. Fresh deferred requests capture from the resolved
`n_past`; exact/prefix reuse shares immutable blocks; accepted speculative
verification rows are committed only at the acceptance boundary; RAM restore
transfers the same archive reference; and activation performs explicit MTP
backfill only when the occupancy policy permits it and the speculative cycle is
idle. Prompt clear, slot-file restore, context shift, checkpoint replacement
and non-contiguous chunk reuse discard the archive before changing target
lineage. Parent/child requests remain target-only. CPU common/server compile
surfaces and the archive/control regression pass.

## DP-07 - validation and documentation

CPU tests must cover archive mechanics and cache ownership before GPU testing.
GPU validation then proceeds in increasing cost:

1. Fresh single-slot capture/backfill reproduces the archived spike's coherent
   512-token result and ordinary MTP drafts.
2. [Complete] Mixed target views publish separate contiguous archives.
3. [Complete] A deferred request remains coherent while target-only decode
   appends rows, then activates MTP at the exact current boundary.
4. [Complete] RAM-cache save/evict/restore preserves target reuse and deferred
   archive identity without hidden-row copying.
5. Immediate MTP, deferred MTP and target-only controls show the expected work
   and no cross-sequence rows.
6. Context shift/non-contiguous reuse drops deferred state but preserves the
   valid target fallback.

Report target capture time, backfill time, retained bytes, aggregate prefill,
decode throughput and MTP proposed/accepted counts separately. The known warm
spike results are comparison evidence, not hard-coded pass thresholds.

Current status: the CPU archive regression also covers cross-slot prefix
extension without copying retained blocks, and server visibility exposes the
selected prefill mode, mutable capture state and finalized archive coverage.

The model-backed mixed-view check used three concurrent MTP-only slots with an
active limit of one. The two deferred slots independently published archives
`1` and `2`; both covered logical positions `0..4558`, contained 4,559 rows and
retained 37,365,900 bytes. Each resident archive then restored the complete
4,559-row target prefix on its own slot, backfilled independently, became MTP
ready and produced ordinary MTP drafts (61/42 and 55/44 proposed/accepted).
Neither continuation contained the other slot's sentinel.

The decode-tail check admitted a second request after the first request was
already active, fixing its prefill selection as deferred. Its target prompt
contained 2,755 rows. It remained deferred with capture active through 2,881
live prompt rows, then backfilled and became MTP ready at the current generating
boundary. The remaining response completed all 256 requested tokens and used
ordinary MTP drafting (123 proposed, 87 accepted), proving that target-only
decode rows after prompt completion were included in synchronization.

The explicit verification contract was then exercised with n-gram still active
while MTP was deferred. A 2,524-row request reached 2,585 live rows while
n-gram verification was occurring, synchronized at 2,589 and completed all 128
requested tokens (67 speculative proposals, 42 accepted). Exact archive/target
position agreement at backfill proves that only the accepted verification
prefix was published; rejected candidate rows were not retained.

The RAM-cache ownership check completed a deferred request under concurrent
demand, displaced its resident slot so the target state plus shared archive
entered the existing RAM cache, made that slot most-recently used, then issued
an unpinned strict extension. LRU selected the other slot. Restore reused 2,165
target rows and evaluated one extension row; the server then activated the same
deferred archive lineage as archive `4` with 2,166 rows. MTP became ready and
the continuation produced 83 draft tokens with 49 accepted. Cache attachment
and take/apply retain the shared archive reference; no hidden-row copy is made
by the RAM-cache path.

## Deferred work

- Leaseable/rotating NextN output buffers and background DRAM copying.
- Preservation through context shift or non-contiguous history remapping.
- Generic multi-completion archive cloning.
- CPU or alternate-GPU backfill.
- Disk-persistent hidden archives.
- Per-client policy overrides.

## Review rule

Each task receives one implementation review against its stated authority and
one focused regression pass before dependent integration proceeds. Review must
look for misplaced ownership and duplicated policy, not demand speculative
guards or abstractions for trusted internal data.
