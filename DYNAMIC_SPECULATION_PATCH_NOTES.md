# Dynamic speculation patch notes

This patch adds server-wide, per-request admission control for speculative
decoding. It is intended for a fixed multi-slot home server that should retain
the single-request benefit of MTP and ngram-mod without paying their full
prompt-processing cost as concurrency rises.

## Runtime policy

The tested four-slot policy is:

```text
--spec-type draft-mtp,ngram-mod \
--spec-active-limit draft-mtp=1,ngram-mod=2
```

The active limit counts occupied streams, including the incoming request:

- one active request: MTP plus ngram-mod;
- two active requests: ngram-mod only;
- three or more active requests: no speculative implementation.

Eligibility is assigned at admission and can only be removed during that
request. Falling concurrency never promotes a surviving request. A later fresh
request is evaluated against the current occupancy.

Omitting `--spec-active-limit` preserves the existing static speculative
behavior.

## What changed

- Added implementation-agnostic loaded and per-sequence eligibility masks to
  `common_speculative`.
- Added fixed-mask ngram begin/draft/accept gating.
- Added eligibility-aware MTP prompt/decode mirroring, raw target-row to compact
  draft-row mapping and explicit unknown/synchronized/invalid state.
- Added exact-target-view NextN switching. MTP views use `(true, false)`;
  views with no target NextN consumer use the normal `(false, false)` mode.
- Added speculative-cycle ownership and safe sticky demotion after verification
  or recurrent replay completes.
- Added per-sequence MTP boundary serialization so synchronized prompt-cache
  restores can resume MTP.
- Changed prompt-cache/checkpoint restoration to retain a successful target KV
  restore when optional draft/speculative state is absent or invalid.
- Added target-only cache records for requests that are not MTP-eligible.
- Refactored slot selection and task preparation so a complete parent/child
  group is selected and all fallible preparation completes before admission
  mutates slots or active requests.
- Added a pure occupied-stream policy planner and a complete server admission
  transaction.
- Added `--spec-active-limit`, startup validation, `/props` policy reporting and
  additive `/slots.speculative_policy` visibility.

## Cache behavior

MTP can resume after RAM-cache restoration only when target KV, draft KV and
the serialized MTP boundary state describe the same prefix. Otherwise the
target cache hit is retained and MTP stays disabled for that request.

An exact prompt-cache hit still requires llama.cpp's normal one-token logits
evaluation. That mutation invalidates MTP. A synchronized strict extension can
retain MTP without reprocessing the complete prefix.

## NextN correction

The initial implementation incorrectly treated `(enabled=false, masked=true)`
as a disabled/cropped mode. Q35 reads `masked` independently and moves row
selection ahead of the final-layer FFN, causing a severe ROCm prefill
regression even though no NextN host copy occurs.

The accepted target-context modes are therefore:

- MTP target hidden rows required: `(true, false)`;
- no target NextN consumer: `(false, false)`.

The unresolved backend performance of legitimate early-cropped
`(true, true)` graphs is recorded separately in `KNOWN_ISSUES.md`.

## Supported implementations

Dynamic active limits currently support:

- `draft-mtp`;
- `ngram-simple`;
- `ngram-map-k`;
- `ngram-map-k4v`;
- `ngram-mod`;
- `ngram-cache`.

A non-empty dynamic policy is rejected when draft-simple, Eagle3, DFlash or
DSpark is loaded because those implementations do not yet apply the
per-sequence eligibility mask throughout their process and draft paths. They
remain available in static mode.

## Validation

Tested on the documented RX 7900 XTX plus R9700 ROCm configuration with Qwen3.6
35B-A3B Q8_0, BF16 target/draft KV, four server slots, batch 8192 and microbatch
1024.

- Short one/two/four-request policy smoke: passed.
- 8K/512 one/two/four screen: passed.
- 8K/4K, one warmup plus three measured waves per mechanism comparison:
  - dynamic one-request prefill versus fixed MTP+ngram: -0.14%;
  - dynamic two-request prefill versus fixed ngram: -2.64%;
  - dynamic four-request prefill versus fixed no-spec: +1.06%;
  - dynamic four-request decode versus fixed no-spec: -2.08%.
- Synchronized solo-MTP RAM restore: 8,447 cached / 1 evaluated, MTP ready.
- Occupancy-two target-only RAM restore: 8,188 cached / 4 evaluated, MTP stayed
  disabled while the target hit was retained.

These are mechanism tests. They do not claim that MTP or ngram improves every
prompt, and speculative decode throughput is not used as a scheduler gate
because acceptance varies with generated content.

## Limitations

- No decode grandfathering or live re-enabling for a surviving request.
- No per-client request override; policy is fixed at server startup.
- No dynamic unloading of MTP weights, compute buffers or recurrent rollback
  storage.
- No generic MTP state cloning for multi-completion parent/child requests.
- Only one stateful speculative implementation is supported by the serialized
  cache envelope.
- Mixed views may still extract target NextN rows globally when any eligible
  MTP sequence needs them; inactive rows are discarded before MTP processing.
- Eagle3 and the other model-draft implementations listed above remain
  static-only.
- The separate intermittent unified-KV scattered-copy slow path is not fixed by
  this feature.

See `DYNAMIC_SPECULATION.md` for the design, the implementation plan for task
boundaries, `KNOWN_ISSUES.md` for deferred faults and
`benchmarks/rocm-yolo/RESULTS.md` for sanitized measurements.
