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
