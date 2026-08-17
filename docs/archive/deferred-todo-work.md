# Deferred todo work

This catalogue owns later investigations and optimizations that are outside
the currently reviewed implementation plans.

## Target KV and serving memory

### Paged unified target-KV memory

Replace the one dense shared KV cell array with fixed-size GPU-resident pages
allocated to logical sequence-position ranges on demand. Each sequence owns a
page table; immutable prefix pages may be shared by reference, completed or
idle sequences return pages to the common pool, and RAM prompt-cache restore
installs whole pages or coalesced page runs rather than issuing one backend
transfer per K/V row and layer.

This is a target-KV storage and attention-addressing project, not an extension
of the hidden archive. Deferred MTP continues to follow the authoritative
logical target lineage without owning its physical KV placement.

Splitting a fragmented restore into larger transfer chunks is a useful
near-term optimization, but it does not remove fragmentation, compact the
shared pool, or stop attention from spanning the dense cache's occupied
high-water mark. The durable design requires a ROCm paged-attention read path
driven by the sequence page table, plus page-aware KV writes, sequence
copy/remove, checkpoint save/restore, and server admission.

Stage the work as: page allocator and lineage tests; page-aware KV
write/restore; numerically equivalent ROCm paged attention; prefix-page
reference sharing; idle-page eviction and RAM restore; then variable-context
concurrency and fragmentation benchmarks against the current unified cache.
Keep this track isolated from the completed DP-01 through DP-07 implementation.

## Model execution

### Cohort-tiled layer-wavefront prefill

Investigate a post-paged-KV execution path that exploits a stable prefill
cohort across physical microbatches. Current `llama_decode()` splits one
logical batch into `n_ubatch`-bounded work and calls `process_ubatch()` once per
physical microbatch at `src/llama-context.cpp:1796-1971`; each call traverses
the complete transformer graph. Graph reuse at
`src/llama-context.cpp:1325-1385` reuses topology and allocations, not
inter-layer activations or a layer-major execution schedule.

The proposed execution shape is:

```text
committed stable prefill cohort
    -> page-backed KV plan and rectangular prompt tiles
    -> layer L over a bounded wave of cohort tiles
    -> retain only the inter-layer activations required by that wave
    -> layer L+1 over the same wave
    -> advance until every committed prompt grant is complete
```

This could amortize layer-weight traffic over substantially more cohort rows,
increase effective matrix width without requiring one whole-model ubatch of
the same size, retain stable GGML/HIP graph shapes, and reduce repeated
whole-model traversals. Treat each claimed gain as a benchmark question:
weights larger than cache, attention cost, activation traffic, kernel launch
cost and ROCm occupancy may move the optimum in different directions.

Paged target KV is the architectural prerequisite. The executor needs stable
page-table addressing, page-aware per-layer KV writes and reads, and immediate
visibility of earlier causal tiles without depending on dense-cache placement
or its occupied high-water range. Paged KV does not itself provide layer graph
partitioning or activation staging; those remain execution-engine work.

Keep authority one-way:

```text
inference::control commits an immutable cohort manifest and prompt grants
    -> server_execution translates the authorized work
    -> model execution chooses the layer-wavefront plan mechanically
```

The controller must not own layer traversal, page tables, activation buffers,
kernel selection or backend events. Conversely, the executor must not alter
cohort membership, prompt fairness, phase barriers or admission.

The investigation must cover:

- A bounded activation ring or wave depth rather than retaining every prompt
  activation across all layers.
- Per-stream causal tile ordering while independent cohort streams execute
  together.
- Layer-fragment graph construction, allocation/reuse and HIP graph capture.
- Output/logit and optional NextN row reconstruction in committed logical order.
- Dense, MoE, hybrid/recurrent, static-LoRA and multimodal model constraints,
  with an initial benchmarkable subset selected from measured value rather
  than leaking model cases into scheduler policy.
- Cancellation and failure boundaries at committed execution units without
  partial controller-owned manifests.
- Interaction with phase-specific `n_batch`/`n_ubatch` geometry; layer tiles
  are an execution detail and do not redefine logical scheduler capacity.

Benchmark first against ordinary full-graph physical microbatches with graph
reuse and HIP graphs enabled. Use long equal and skewed prefill cohorts, sweep
tile width and wave depth, and measure accepted prompt tokens/s, whole-model
traversals, per-layer weight/activation traffic, attention traffic, launch
overhead, GPU occupancy, peak VRAM and page-table overhead. Decode is a
secondary case because ordinary cohort verification rows will generally fit
inside one physical ubatch already.

## Speculative execution and batching

### Phase-aware dynamic cohort batch sizing

Tune cohort prefill and decode as distinct ROCm workloads instead of forcing
both through one fixed `n_batch`/`n_ubatch` geometry. Add a cohort controller
that selects separately benchmarked batch and microbatch sizes for prefill,
ordinary decode, and speculative verification from the current phase mix,
ready sequence count, and token shape. Change geometry only at an existing
cohort boundary and retain compute graphs for a small tuned set of geometries
rather than rebuilding for every fluctuation.

Measure prompt throughput, aggregate decode throughput, TTFT, inter-token
latency, GPU occupancy, and peak VRAM across pure and mixed prefill/decode
cohorts on gfx1100, gfx1151, and gfx1201. This is a ROCm-first optimization;
backend-independent policy or kernels are not a requirement.

### Manifest-view-aware speculative processing

Explore processing different atomic speculative blocks in different server
`batch_view`s. The investigation must cover:

- View-specific speculative membership passed to
  `common_speculative_process()`.
- Safe local/global `spec_i_batch` mapping.
- Output/logit indexing and `n_outputs_max`.
- `common_sampler_sample_and_accept_n()`.
- NextN extraction and acceptance.
- Checkpoint rollback and replay.
- Cancellation and per-view outcome reporting.

Each stream's verification block must remain atomic. Physical `n_ubatch`
microbatching remains unrelated and unchanged. Durable committed-manifest and
controller seams may make this optimization easier, but it is not part of the
cohort authority refactor.

### Dynamic mid-decode MTP reconstruction

Current backfill requires target `pos_max == archive.pos_end` at
`common/speculative.cpp:1573-1576`. After target-only decode advances,
`server-context.cpp:3530-3533` drops the invalid archive. Explore midstream
target/draft reconstruction, history, dynamic implementation selection,
checkpoints, demotion, replay, and whether the throughput gain justifies the
new lifecycle.

### Additional deferred MTP work

- Leaseable/rotating NextN output buffers and background DRAM copying.
- Preservation through context shift or non-contiguous history remapping.
- Generic multi-completion archive cloning.
- CPU or alternate-GPU backfill.
- Disk-persistent hidden archives.
- Per-client policy overrides.

## Prompt checkpoints

### DRAM-copy optimization

Measure prompt-checkpoint creation and restore copies in
`common_prompt_checkpoint::update_tgt()` and `update_dft()` at
`common/common.cpp:2143-2176`. These paths currently serialize sequence state
into owning byte vectors through `llama_state_seq_get_data_ext()`.

Investigate a DRAM-resident buffer reuse/copy-reduction path that lowers
checkpoint overhead without moving checkpoint ownership into the scheduler.

## Controller authority and safety

### Decode-failure whole-context sweep

When `llama_decode()` fails at `server-context.cpp:4401-4417`, the current
error path releases every processing slot and clears its prompt/prompt-cache
key across all slots at once — a broad mutation mid-iteration. Under the
centralized controller this bypasses phase and authorization boundaries.

This must be classified and assigned an explicit owner:
`server_execution` may detect and report the failure, but the scope of
cleanup (which slots, whether model/cache state is affected) is a policy
decision that belongs to `inference::control`. Execution must never
independently sweep all processing slots or mutate prompt cache keys without
an authorized command.

The investigation must cover:
- Whether the failure is always unrecoverable (every processing slot must
  abort) or whether slot-scoped recovery is possible for some failures.
- Whether `clear_mtp_archive()`, `prompt_clear()` and `prompt_cache_key.clear()`
  are always safe when a decode has partially committed rows.
- Authorized abort/cleanup command shape: scoped to a single failed slot vs
  the full affected batch membership vs all processing slots.
- Interaction with the `verification_prefix_unfit` path and Phase 3
  transfer of the unfit decision to control.

### Ungated global adapter write (SET_LORA)

The `SERVER_TASK_TYPE_SET_LORA` path at `server-context.cpp:3313-3325` writes
the global `params_base.lora_adapters` table without waiting for a quiescent
boundary. It works today by luck of queue ordering (tasks drain before
`update_slots()`), but under the centralized controller a decode batch could
be mid-preparation when the write lands, changing adapter signatures across
in-flight work.

Gate this at a controller phase boundary:
- `SET_LORA` becomes a boundary-gated model mutation.
- Only `model_mutation_commit` (from `inference::control`) authorizes
  `server_execution::executor` to apply the write mechanically.
- The committed mutation takes effect at the next `target_batch_commit` via
  the existing `common_set_adapter_lora()` seam at `server-context.cpp:3447-3448`;
  no mid-iteration or mid-preparation write survives.
