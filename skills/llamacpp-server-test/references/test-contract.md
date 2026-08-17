# Test contract

## Contents

- Protocols
- Metrics
- Coherence
- Comparison selection
- Required report

## Protocols

| Mode | Warmup | Measured | Purpose |
|---|---:|---:|---|
| Proof of concept | custom | custom | Prove a mechanism exists and functions. State the exact custom protocol. |
| Quick and dirty | 1 | 1 | Mid-workflow detection of obvious breakage or regression. |
| Final testing | 1 | 3 | Measure actual behavior and confirm the implementation. |

A warmup is the complete intended workload, not a small health request. Do not include warmup results in measured aggregates.

## Metrics

For one request, use the server's actual `prompt_n`, `predicted_n`, and phase timing.

For synchronized concurrency:

```text
aggregate prefill = total actual prompt_n / release-to-latest-first-token
active decode     = total actual predicted_n / earliest-first-token-to-latest-finish
```

Report prompt/decode sizes per request and simultaneous request count. Never present `sum(per-slot prompt t/s)`.

## Coherence

Coherence answers only: did inference produce structurally sane language rather than backend corruption or token soup?

Hard failures:

- process/runtime/backend failure;
- NaN, allocator or explicit corruption signal;
- null/replacement characters;
- exact foreign-request sentinel;
- empty or obvious repetitive garbage output;
- wrong forced output length when exact generation length is part of the protocol.

Warnings only:

- missing/mutated self-sentinel;
- malformed reasoning tags;
- changed wording, facts, style, or reasoning;
- non-identical output across builds.

Use `PASS`, `PASS (warnings)`, or `FAIL`. Preserve warning details separately.

## Comparison selection

Select a historical ROCm YOLO baseline lexicographically:

1. speculation set (`none`, `ngram-mod`, `mtp`, `mtp+ngram-mod`);
2. batch/microbatch;
3. active requests/server slots;
4. prompt/decode tokens;
5. KV layout.

Do not compare a no-spec result with MTP merely because request counts match. Label a non-exact historical match directional.

Require a live pre-dynamic YOLO control when prefill differs by more than 5%, decode differs by more than 10%, coherence changes, or exact equivalence/regression matters. Decode thresholds are wider because speculative acceptance changes with generated content.

## Required report

```markdown
Claim: <one sentence>
Protocol: <mode, warmup, measured, active requests/server slots>

| Build/test | Prefill t/s | Decode t/s | Prefill size | Decode size | Batch/microbatch | Coherence |
|---|---:|---:|---:|---:|---:|---|
| Current | ... | ... | ... | ... | ... | PASS |
| Closest ROCm YOLO | ... | ... | ... | ... | ... | PASS |

Difference: prefill ...%; decode ...%.
Comparison quality: exact live / exact historical / directional.
Warnings: ...
```

For final mode, list all three measured values after the table.
