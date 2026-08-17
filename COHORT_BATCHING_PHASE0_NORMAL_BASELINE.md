# Phase 0 NORMAL Scheduling Baseline

Status: review freeze for the cohort-batching authority migration.

This document freezes the source-derived compatibility definition for the
current NORMAL server scheduler before any authority moves. The companion
machine-readable fixtures are in
`tests/python/fixtures/cohort_batching_normal_manifest_baseline.json`.

## Evidence boundary

The inspected repository base is
`91a5c4911c86fa9e8b85fda27be0e6abeb75b574`. The source files below also
contained pre-existing user-owned changes when this baseline was captured.
Their exact SHA-256 values are recorded in the fixture file. The baseline
therefore names the inspected contents, not merely the repository base commit.

No diagnostic instrumentation, server execution, model load or GPU test was
performed in Phase 0. Current code has no `iteration_id`, no emitted
`target_manifest`, and no passive reconciled-progress projection. Synthetic
fixture identities and row values make the current source rules concrete; they
are not represented as a captured production trace. Phase 2 introduces the
mechanical translator needed to compare live manifests with these fixtures.

The current scheduling turn is one `update_slots()` invocation. The fixture
field `legacy_turn` names that synthetic turn. Its `iteration_id` remains null
until the architecture supplies one.

Fixture capacity vocabulary is exact. `actual_constructed_rows` is what the
legacy batch contains in the concrete example. `maximum_possible_rows` is a
configuration/context bound, not a reservation. `legacy_reserved_rows` is
always null because the current scheduler does not reserve worst-case rows
before drafting. Worst-case reservation belongs to the proposed controller and
must not be projected backward onto this baseline.

## Current authority and order

1. `server_queue::start_loop()` drains every currently queued task through
   `callback_new_task()` and then invokes `callback_update_slots()` once
   (`tools/server/server-queue.cpp:125-208`). A cancellation removes queued and
   deferred instances when posted and releases an attached matching task before
   the following update (`server-queue.cpp:22-69,211-221` and
   `server-context.cpp:3053-3062`).
2. Admission, slot selection and attachment are still performed directly in
   `process_single_task()` (`server-context.cpp:2817-3052`). Parent and child
   slots are prepared together; children attach as `WAIT_OTHER`.
3. `update_slots()` calls `pre_decode()`, renders one `server_batch`, applies
   the selected batch adapter/embedding mode, creates logical batch views,
   calls target `llama_decode()`, and calls `post_decode()` for every successful
   view (`server-context.cpp:3392-3500`). There is no separate controller.
4. `pre_decode()` performs context shift, deferred-MTP scans, speculative draft
   preparation, sampled/verification prefix construction, then prompt-tail
   filling (`server-context.cpp:3543-4331`).
5. `decode()` invokes target execution and common speculative processing;
   retry reduces the effective logical view size after cache pressure
   (`server-context.cpp:4333-4458`).
6. `post_decode()` performs embedding/rerank responses, ordinary sampling,
   speculative verification/acceptance, rollback/replay and response-visible
   token processing (`server-context.cpp:4460-4701`).

This is deliberately a description of the authority that exists today. It is
not the desired component contract.

## Batch identity and capacities

`server_batch` stores each logical row as `(slot_id, token, position, output)`
and renders those rows into one `llama_batch` (`server-context.cpp:138-263`).
The current row identity contains only `slot_id`; the exact `task_id` must be
joined from the attached slot. Fixtures spell the pair as `stream_key` to make
slot reuse visible without claiming that the current batch carries it.

The target context's `n_batch` is the logical server batch/view capacity. The
batch storage is initialized to that capacity (`server-context.cpp:1696`) and
prompt filling stops at it (`server-context.cpp:3747-3760,4211-4267`). The
target context's `n_ubatch` is a physical execution limit used below
`llama_decode()` and for prompt/checkpoint constraints; it is not a server
scheduler admission budget (`server-context.cpp:3747-3749,3838-3848,4247-4258`,
`src/llama-context.cpp:1713-1817`, and `src/llama-batch.cpp:481-725`).

On cache-pressure retry, `decode()` halves the effective logical view size if
an idle-slot clear cannot recover capacity. The outer loop retries the same
offset and, after success, continues through the remaining prompt tail
(`server-context.cpp:3460-3499,4364-4416`).

## Current row construction

### Decode and verification prefix

Generating slots compatible with the first selected slot are collected before
prompt rows. Draft parameters are populated for all such slots, the existing
bulk `common_speculative_draft()` is called once, and each stream then appends:

- one sampled-token row when no draft exists; or
- one sampled-token row followed by every actual draft row.

Every row in a speculative block requests output. `spec_i_batch` stores the
complete global row-index sequence, so actual verification rows equal
`1 + spec_draft.size()` (`server-context.cpp:3626-3745` and
`server-context.cpp:617-676`). Actual draft length can be below the configured
maximum.

The effective maximum proposal count is the maximum across every enabled
implementation (`common/speculative.cpp:2780-2813`). Current defaults include:

- draft model/MTP: 3 proposals, hence at most 4 target rows per stream
  (`common/common.h:329-331`);
- ngram-mod: 64 proposals with minimum 48, hence at most 65 target rows per
  stream (`common/common.h:370-375`);
- ngram map variants: their configured `size_m`;
- ngram cache: 8 proposals.

These maxima constrain output allocation and describe the worst case, but the
legacy scheduler prepares first and appends actual rows. It does not yet make
the proposed controller's worst-case reservation commit.

ngram-mod has a stronger raw implementation-result constraint than “shorter
than maximum.” It returns no raw proposal when the first miss occurs below
`n_min`; otherwise its raw result count is within `[n_min, n_max]`. At current
defaults that is zero or `[48, 64]` (`common/speculative.cpp:2424-2442`). After
that implementation returns, legacy `common_speculative_draft()` truncates the
result to the stream's `dp.n_max` (`common/speculative.cpp:3393-3397`). The
server derives that cap from remaining context and output budget before draft
preparation (`server-context.cpp:617-635,3650-3681`). Consequently, final
legacy proposal rows may be `1..47` near those limits even though ngram-mod
itself never returns a raw result in that interval. This is legacy truncation,
not the future controller's explicit sampled-only fallback below ngram
`n_min`.

With multiple implementations enabled, `common_speculative_n_max()` supplies
the maximum possible proposal count across them, while
`common_speculative_draft()` runs implementations in fixed internal priority
until one returns a nonempty result for the stream and records that exact
implementation as `impl_last` (`common/speculative.cpp:3323-3421`). Requested
type list order does not determine this priority: initialization first collapses
requested types to an enabled bitmask, then constructs implementations in one
hard-coded ngram-first/draft-second order
(`common/speculative.cpp:2936-2963`). Therefore maximum row pricing, raw
implementation output, the per-stream cap and the final selected result are
separate fixture fields.

### Prompt tail

When continuous batching is enabled, or when the decode prefix is empty, the
server iterates slots in its existing order and appends prompt rows until
`n_batch` is full. With continuous batching disabled, a nonempty decode prefix
prevents prompt work in that turn (`server-context.cpp:3747-3779`). Thus one
logical target batch can contain both decode/verification rows and prompt rows.

Prompt rows normally request output only at the last prompt token. Embedding
work and speculative implementations requiring prompt embeddings request
outputs according to `slot.need_embd()`; embedding/rerank tasks may require all
prompt rows (`server-context.cpp:518-531,4210-4235,4279-4291`).

A fully reusable prompt is deliberately backed up by one token so that the
active slot evaluates a last-token logits row (`server-context.cpp:4076-4082`).
That row belongs to prompt reconciliation, not an already-pending sampled-token
decode.

### Compatibility and adapter signature

The first selected slot fixes the current batch's mechanical compatibility.
Another slot can join only when task type, input-embedding width and the full
LoRA vector compare equal (`server-context.cpp:534-540,3629-3642,3763-3770`).
The fixtures encode an adapter signature as the exact ordered adapter entries
and exact scales. The synthetic `adapter_index` is a stable fixture name for
the exact loaded adapter identity at that ordered position; current equality is
actually ordered pointer identity plus exact scale, not path text or a numeric
runtime adapter ID (`tools/server/server-common.cpp:144-156`). Base/no-LoRA is
the empty ordered set. Different static LoRA signatures do not share a current
target batch. aLoRA can require a separate pre-invocation target batch with its
adapter temporarily disabled (`server-context.cpp:4145-4157,4218-4224`).

### Parent and child streams

Children attach in `WAIT_OTHER` and contribute no rows. After the parent's
prompt view succeeds, target and prompt/sampler state is copied to every child,
which becomes `DONE_PROMPT`; ordinary post-decode sampling can then use the
copied parent output index (`server-context.cpp:2245-2246,3772-3776,4434-4453`
and `server-context.cpp:924-941`). The child is not independently runnable or
countable before that copy.

### Multimodal direct target operation

Media chunks are not represented in `server_batch`. During prompt preparation,
`process_mtmd_chunk()` may encode multiple media chunks and calls
`mtmd_helper_decode_image_chunk()` directly for the exact slot/task. Common
speculative processing is invoked through its callback
(`server-context.cpp:943-1032,4174-4205`). The fixture therefore records an
`external_target_operation`, not synthetic token rows for opaque media-helper
batches.

## View and outcome compatibility

Ordinary prompt/sample post-processing skips a slot whose `i_batch` is not in
the current logical view (`server-context.cpp:4481-4492`). Speculative
post-processing is different: before any per-slot work, every nonempty
`spec_i_batch` must be wholly contained in the current view
(`server-context.cpp:4422-4428,4460-4474`). Consequently, the complete union of
current sampled/speculative verification blocks must remain in the first retry
view. A retry may split only the prompt tail. If effective capacity cannot fit
the whole prefix, current code throws rather than processing a partial block.

Ordinary sampling consumes the row at `i_batch`, increments `n_decoded`, emits
the token and either retains or releases the slot (`server-context.cpp:4510-4575`).
Speculative verification requires `spec_i_batch.size() == spec_draft.size()+1`,
calls `common_sampler_sample_and_accept_n()`, and either:

- accepts and advances the prompt/output state;
- restores the checkpoint and retains an explicit replay; or
- releases after a response-visible stop.

Those consequences are one lifecycle (`server-context.cpp:4577-4701`;
`common/sampling.cpp:678-714`; `common/speculative.cpp:3267-3454`). Prepared
draft extent and mutable target/draft memory positions are retractable and must
not be treated as committed output progress.

Context shift likewise removes and relocates physical memory/prompt extent
without decreasing response-visible accepted output (`server-context.cpp:3543-3611`).

## Field classification

| Current field/evidence | Classification | Baseline meaning |
| --- | --- | --- |
| attached `slot.id` + `slot.task->id` | exact current-task identity | Must be read together; neither is a cohort identity |
| `slot.state` | lifecycle gate | Determines whether prompt, sample, child-copy or no work is legal |
| `slot.prompt.n_tokens()` after reconciliation | current logical prompt coverage | Mutated by cache/checkpoint reconciliation; Phase 0 cannot passively observe a pre-mutation reconciled projection |
| `slot.n_decoded` | response-visible committed output count when lifecycle-valid | Reset at prompt completion; copied to children; stale slot storage is not independently authoritative |
| `slot.sampled` with generating lifecycle | pending sampled input | Already accepted/output-visible but still owes target evaluation |
| `slot.spec_draft`, `slot.spec_i_batch`, `slot.spec_ckpt`, `spec_is_replay` | prepared/retractable speculative lifecycle | Moves together through verification, rollback and replay |
| target/draft memory positions and prompt checkpoints | physical/reconstructive state | May move or restore without output regression |
| `n_batch` | logical row/view capacity | Scheduler construction and retry-view budget |
| `n_ubatch` | physical microbatch capacity | Internal model execution and unsplittable-task constraints |

## Fixture catalogue and expected outcomes

The JSON catalogue contains concrete examples or source-rule templates for all
Phase 0 cases:

1. target-only generation;
2. speculative generation with actual draft shorter than maximum, including
   dynamic selection from multiple eligible implementations;
3. mixed decode and prompt continuous batching;
4. prompt-only continuous batching;
5. `--no-cont-batching` with and without a decode prefix;
6. base, identical static LoRA, mixed LoRA, and aLoRA boundaries;
7. parent/child prompt completion;
8. cache hit, checkpoint restore, and fully cached forced-logits evaluation;
9. embedding and rerank output rows;
10. multimodal external target execution;
11. deferred-MTP immediate, deferred activation and target-only outcomes;
12. atomic verification-prefix retry;
13. cancellation before the next inference turn;
14. context shift; and
15. speculative checkpoint replay.

For source-rule templates, concrete row counts are intentionally expressed as
formulas because they depend on prompt/cache/model output that was not executed
in Phase 0. Phase 2 comparison must substitute the emitted actual values while
preserving ordering, identity, row-kind, adapter and outcome invariants.

## Baseline gate

Phase 0 is satisfied when:

- the two architecture documents and these fixtures are reviewed as one frozen
  documentation commit;
- every fixture refers to an exact source region and distinguishes observed
  source behavior from unavailable transient data;
- JSON parses and every declared source file/range resolves;
- no runtime source, authority, build graph or behavior changes; and
- Phase 1 starts from this commit without revising the baseline to match new
  behavior.
