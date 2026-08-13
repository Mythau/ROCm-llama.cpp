# Known issues

## KV-RESTORE-001: intermittent slow unified-cache checkpoint restore

Status: reproduced; cause strongly suspected but not yet instrumentally confirmed.

Observed with Qwen3.6-35B-A3B Q8_0, BF16 KV, four slots and unified KV cache:

- Checkpoint size: 70.055 MiB
- Checkpoint position count: 3,668
- Normal restore: approximately 85 ms
- Slow restore: 7.811 seconds
- Effective bandwidth during the slow restore: approximately 8.97 MiB/s
- Expected row copies: 3,668 positions x 10 layers x K/V = 73,360
- Implied cost: approximately 106 microseconds per row copy

The timing is consistent with the non-contiguous restore path issuing one small `hipMemcpyAsync` followed by `hipStreamSynchronize` for each tensor row. The current logs do not record contiguity, row count or run count, so this remains a high-confidence diagnosis rather than a confirmed causal trace.

Next work:

1. Record restore contiguity and row/run counts.
2. Reproduce restoration over an occupied unified-cache sequence.
3. Coalesce adjacent rows or relocate the sequence before restoration.
4. Confirm that the intermittent restore returns to approximately 85 ms.

## TEST-WIN-001: standalone speculative-control test divides by zero

Status: resolved; the standalone control test has been restored with test-local
timer initialization.

The isolated Windows CPU test executable `test-speculative-control.exe` exited
with integer divide-by-zero (`0xC0000094`) while exercising speculative
`begin()`. The live server, GPU inference and production binary were not
involved.

The removed fixture called `common_speculative_begin()` without first
initializing GGML timing. On Windows, `ggml_time_us()` therefore divided by the
zero-initialized `timer_freq`. Production llama-server is unaffected because it
calls `llama_backend_init()`, which initializes GGML timing before speculative
work.

The restored test calls `ggml_time_init()` inside its test function, immediately
before constructing and exercising the timed speculative control system. No
server entry-point, speculative implementation or GGML timing guard was added.

## NEXTN-DYNAMIC-001: other draft implementations are not supported by dynamic active limits

Status: known limitation; deliberately excluded from the accepted Q35 MTP path.

The accepted dynamic NextN implementation switches the target context per exact batch view for Q35 MTP:

- A view requiring MTP target hidden rows uses `(enabled=true, masked=false)`.
- A view with no target NextN consumer uses `(enabled=false, masked=false)`.

Eagle3 is not yet safe under the same per-sequence dynamic policy. Its target-output requirement is eligibility-aware, but its `process()` path still processes every target row. An entirely ineligible Eagle3 view could therefore disable NextN before Eagle3 attempts to read it, while a mixed view can still mutate ineligible Eagle3 state. Eagle3's non-final target-layer taps also remain configured globally.

Draft-simple, DFlash and DSpark likewise do not consume the per-sequence eligibility mask throughout their process and draft paths. `--spec-active-limit` therefore rejects servers that load any of these implementations instead of exposing a policy state that does not control execution.

Draft-context NextN modes remain configured by their implementations at construction. This work does not dynamically switch or claim performance savings for those contexts. Dynamic Eagle3 or draft-context support requires a separate implementation and validation pass.

## NEXTN-ROCM-001: early-cropped Q35 final layer is slow on ROCm

Status: reproduced; causal graph branch identified; backend-level cause not profiled.

On Q35 and Q35MoE, `masked=true` moves `ggml_get_rows` ahead of the final-layer FFN. This happens independently of `enabled`, so `(enabled=false, masked=true)` disables NextN host extraction but still selects the early-cropped target graph. A genuine two-slot ngram-only test at batch 2048 / microbatch 512 measured approximately 2,786 t/s aggregate prefill in that mode, versus 3,890 t/s measured and 4,065 t/s warm after restoring the normal `(false, false)` graph. The original YOLO mean was approximately 4,091 t/s.

The accepted fix avoids this topology when no NextN consumer exists. It does not explain why the early-cropped graph is pathological on this ROCm build, nor does it change legitimate `(true, true)` users. A later external `rocprof` comparison may be worthwhile if masked NextN becomes an important workload; no profiling or instrumentation is included here.
