# Performance results

## Dynamic speculative scheduler mechanism validation

Qwen3.6 35B-A3B Q8_0 with embedded MTP, four-slot server, partitioned BF16 KV,
batch 8,192 / microbatch 1,024, 8,192 prompt tokens and 4,096 generated tokens.
Occupancy changes the admitted implementation mask while server capacity stays
fixed at four slots.

| Active requests | Dynamic mode | Dynamic prefill median | Matching fixed control | Fixed prefill median | Difference |
|---:|---|---:|---|---:|---:|
| 1 | MTP + ngram-mod | 4,385.8 | MTP + ngram-mod | 4,392.1 | -0.14% |
| 2 | ngram-mod | 4,710.7 | ngram-mod | 4,838.7 | -2.64% |
| 4 | none | 4,777.8 | none | 4,727.7 | +1.06% |

All three dynamic configurations completed one warmup and three measured waves
without runtime or hard output-integrity failure. Slot visibility confirmed the
effective masks: MTP + ngram-mod at occupancy one, ngram-mod only at occupancy
two, and an empty speculative mask at occupancy four. At four active requests, where
both sides perform no speculative decoding, dynamic decode was 164.41 t/s versus
167.91 t/s fixed no-spec (-2.08%) and end-to-end generation was 156.48 versus
159.49 t/s (-1.89%). This measures the residual cost of keeping the dynamic MTP
machinery resident. Single- and two-request speculative decode rates are not
used as scheduler gates because acceptance varies with generated content.

Unified RAM-cache interaction also passed:

| Restore case | Cached tokens | Evaluated tokens | Post-restore state |
|---|---:|---:|---|
| Synchronized solo MTP, strict extension | 8,447 | 1 | MTP ready |
| Target-only entry created at occupancy two | 8,188 | 4 | MTP disabled; target hit retained |

The target-only restore still used ngram-mod drafting. That is expected and is
not MTP promotion.

## Single-request 8K prefill comparison

Qwen3.6 35B-A3B Q8_0, BF16 KV, no speculation:

| Build | Runs | 8K prefill t/s | Relative to mainline |
|---|---:|---:|---:|
| Mainline | 3 measured | 4,231.5 mean | baseline |
| PR 26856 | 3 measured | 4,297.0 mean | +1.5% |
| ROCm YOLO | 1 warm | 4,890.8 | +15.6% |

The YOLO result is also 13.8% above the archived PR-26856 mean. Because the YOLO
row contains only one warm run, it is a strong signal rather than a final
cross-machine benchmark.

Earlier operational observations around 3.9k t/s are not used as the formal 8K
baseline because the retained like-for-like mainline 8K data averages 4,231.5
t/s.

## Four-slot 8K/4K service matrix

Four simultaneous 8,192-token prompts, 4,096 generated tokens each, batch 8,192,
microbatch 1,024, partitioned BF16 KV and continuous batching:

| Speculation | Aggregate prefill t/s | Active decode t/s | End-to-end generated t/s | Clean measured waves |
|---|---:|---:|---:|---:|
| None | **4,735.7** | 168.92 | 160.46 | 3/3 |
| MTP | 4,280.3 | **170.94** | **161.48** | 2/3 |
| ngram-mod | 4,623.1 | 141.62 | 135.59 | 1/3 |
| MTP + ngram-mod | 4,160.7 | 147.63 | 140.48 | 1/3 |

For this disjoint concurrent workload, no speculation produced the best clean
balance. MTP gained about 1.2% active decode but lost about 9.6% aggregate
prefill. N-gram was not advantageous because the prompts deliberately did not
share repetitive continuation structure.

## Synchronized concurrency sweep

Batch 2,048 / microbatch 512, partitioned BF16 KV:

| Slots | Speculation | Aggregate prefill t/s | Active decode t/s | End-to-end generated t/s |
|---:|---|---:|---:|---:|
| 2 | none | 4,110.0 | 118.99 | 114.28 |
| 2 | ngram-mod | 4,090.5 | 106.38 | 102.57 |
| 2 | MTP | 3,400.7 | 138.24 | 130.57 |
| 2 | MTP + ngram-mod | 3,338.3 | 123.91 | 117.68 |
| 4 | none | 3,870.6 | 159.47 | 154.69 |
| 4 | ngram-mod | 3,774.8 | 143.58 | 139.68 |
| 4 | MTP | 3,312.6 | 166.81 | 160.55 |
| 4 | MTP + ngram-mod | 3,313.5 | 146.37 | 141.54 |
| 8 | none | 3,784.4 | 205.25 | 200.44 |
| 8 | ngram-mod | 3,800.5 | 181.29 | 177.68 |
| 8 | MTP | 3,240.4 | 203.35 | 197.83 |
| 8 | MTP + ngram-mod | 3,120.5 | 178.41 | 174.18 |

MTP helped active decode at two and four slots, but its advantage disappeared at
eight. N-gram was a loss on these disjoint prompts. This is the empirical basis
for investigating admission-driven speculative modes rather than enabling one
static speculative configuration for every concurrency level. That scheduler is
not implemented in the published branch.

## Batch and microbatch trade-off at eight slots

No speculation, 8K prompt / 4K generation:

| Batch / microbatch | Aggregate prefill t/s | Active decode t/s | End-to-end generated t/s |
|---|---:|---:|---:|
| 2,048 / 512 | 3,845.4 | **204.12** | **199.64** |
| 8,192 / 1,024 | **4,528.8** | 197.71 | 190.96 |

The larger batch improves prompt throughput while slightly reducing decode and
complete-wave throughput. It is useful when prefill latency or admission rate is
the priority.

## Single-stream speculation examples

Qwen3.6 35B-A3B, one 8K prompt followed by 8K generation:

| Mode | Prefill t/s | Decode t/s | Draft acceptance |
|---|---:|---:|---:|
| None | 4,890.8 | 73.43 | n/a |
| MTP | 3,815.4 | 106.58 | 5,586 / 7,814 (71.5%) |
| MTP + ngram-mod suite mean | 3,828.4 | 143.57 | 19,258 / 28,285 (68.1%) |

The combined run used a repetitive synthetic continuation favorable to n-gram.
One other 35B combined-suite run entered a repetition/Unicode-replacement loop,
so the combined configuration is not presented as a clean universal result.

The 27B combined suite was slower in absolute terms and had one extra closing
reasoning tag, but no null-byte or token-soup pattern. These observations are
included as correctness caveats rather than headline performance claims.
