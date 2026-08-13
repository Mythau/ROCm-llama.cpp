# Benchmark methodology

## Aggregate prefill

For synchronized concurrent requests, aggregate prefill is:

```text
total prompt tokens / time from synchronized release to the latest first token
```

This measures server prompt-admission capacity across the complete wave. Every
prefill number in this package is either that aggregate measurement or a directly
reported single-request prompt evaluation rate. The two protocols are labelled
separately.

## Aggregate decode

For synchronized requests, active decode is:

```text
total generated tokens / time from the earliest first token to final completion
```

End-to-end generated throughput uses the complete wave wall time.

## Workloads

The principal four-slot workload used:

- four distinct 8,192-token prompts;
- forced generation of 4,096 tokens per request;
- partitioned BF16 KV;
- continuous batching;
- batch 8,192 and microbatch 1,024;
- one complete warm-up wave followed by three measured waves.

Dynamic scheduler comparisons kept `--parallel 4`, context 50,176, batch 8,192
and microbatch 1,024 fixed for every one/two/four-request run. Only the number of
simultaneously submitted requests changed. Each dynamic mode was compared with
the same fixed speculative mode; the four-request fully gated state was compared
with a separately launched no-spec server.

The broader synchronized concurrency sweep used 8,192-token prompts and 4,096
generated tokens at 2, 4 and 8 slots with batch 2,048 / microbatch 512.

The two-slot MTP-only build comparison used three fresh server processes per
build, with exactly one synchronized two-request wave per process. This avoids
resident-prefix reuse changing stateful speculative eligibility between waves.
The resident-but-gated comparison used the normal one-warmup/three-measured-wave
protocol on the same dynamic binary and compared `draft-mtp=1` against a true
no-spec server.

The unified-KV cache test used four distinct 8K prompts, a churn wave, and then an
exact-prefix restore wave. Restored-token accounting was taken from the server
response. TTFT is the client-observed request-to-first-token interval.

## Output checks

The concurrency harness treated exact cross-request sentinels, wrong generated
token counts, null bytes and Unicode replacement characters as hard failures.
Missing or mutated self-sentinels and malformed reasoning tags were recorded as
model-behavior warnings rather than backend corruption.

Raw model text is deliberately excluded from this package.

## Repetition and limitations

- Mainline single-request 8K: three measured runs.
- YOLO single-request 8K headline: one warm run.
- Four-slot 8192/1024 matrix: three measured waves after warm-up.
- Synchronized concurrency matrix: three measured waves after warm-up.
- Two-slot active-MTP build comparison: three independent fresh-server waves
  per build.
- Two-slot resident-but-gated comparison: three measured waves after warm-up.
- Unified-KV post-fix result: one complete rerun of the cache lifecycle.

The YOLO single-request headline therefore needs additional independent repeats.
The four-slot aggregate result has the stronger repetition count.
