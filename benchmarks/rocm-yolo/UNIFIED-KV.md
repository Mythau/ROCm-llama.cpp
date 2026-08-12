# Unified-KV prompt-cache restoration

## Failure before the patch

Four exact-prefix 8K requests were successfully found in the RAM prompt cache:

- cached prompt tokens: 32,752
- evaluated prompt tokens: 16
- restored TTFT p50: 56,892.3 ms
- restored TTFT p95: 56,893.3 ms

The cache did not miss and the prompt was not recomputed. The latency occurred
while restoring cached state into unified GPU KV storage.

Source and log analysis found that scattered destination cells cause the restore
reader to issue one synchronous backend write for every K/V cell and layer. For
the observed 8,447-token Qwen hybrid entry, the slow path implied:

```text
8,447 cells x 10 attention layers x 2 K/V tensors = 168,940 writes
```

## Patch

Commit `40843ed0d` asks the unified KV allocator for a contiguous destination
range first. If one is unavailable, it logs the condition and retains the
existing scattered-placement fallback.

## Result after the patch

The final complete rerun reported:

- cached prompt tokens: 32,752
- evaluated prompt tokens: 16
- restored TTFT p50: **2,812.6 ms**
- restored TTFT p95: **2,813.6 ms**
- restored-stage audit: passed

That is a **20.2x reduction** in restored TTFT relative to the pre-patch result.
It was also substantially faster than the 8,735.6 ms cold TTFT in the same final
run.

An earlier patched run measured 3,112.1 ms p50. The independent rerun therefore
supports a patched range of approximately 2.8-3.1 seconds for this four-request
test.

## What this proves and does not prove

It proves that contiguous-first restore placement removes the severe observed
unified-KV restore regression on this workload and hardware.

It does not:

- guarantee that a sufficiently large contiguous range always exists;
- compact a fragmented cache;
- make prompt-cache transfer asynchronous;
- remove the scattered fallback;
- serialize missing MTP boundary state.

When contiguous allocation fails, the old slow path remains possible. A future
coalesced scattered restore would address that remaining case.

