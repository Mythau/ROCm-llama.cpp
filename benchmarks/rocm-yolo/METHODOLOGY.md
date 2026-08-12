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

The broader synchronized concurrency sweep used 8,192-token prompts and 4,096
generated tokens at 2, 4 and 8 slots with batch 2,048 / microbatch 512.

The unified-KV cache test used four distinct 8K prompts, a churn wave, and then an
exact-prefix restore wave. Restored-token accounting was taken from the server
response. TTFT is the client-observed request-to-first-token interval.

## Output checks

The concurrency harness checked request completion, expected sentinel presence,
output length, null bytes and Unicode replacement characters. Some strict
sentinel failures were model-generated identifier mutations rather than transport
corruption; they remain counted as failures in the clean-wave totals.

Raw model text is deliberately excluded from this package.

## Repetition and limitations

- Mainline single-request 8K: three measured runs.
- YOLO single-request 8K headline: one warm run.
- Four-slot 8192/1024 matrix: three measured waves after warm-up.
- Synchronized concurrency matrix: three measured waves after warm-up.
- Unified-KV post-fix result: one complete rerun of the cache lifecycle.

The YOLO single-request headline therefore needs additional independent repeats.
The four-slot aggregate result has the stronger repetition count.

