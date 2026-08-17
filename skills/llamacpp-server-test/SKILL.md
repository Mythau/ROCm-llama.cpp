---
name: llamacpp-server-test
description: Plan, run, summarize, and compare llama.cpp server inference tests on this ROCm YOLO workspace. Use for proof-of-concept checks, mid-workflow quick regression checks, final performance validation, concurrent server tests, MTP or ngram comparisons, batch/microbatch tuning, coherence checks, and comparisons against the pre-dynamic-speculation ROCm YOLO build.
---

# Test llama.cpp server changes

Standardize test intent, invocation, repetition, measurements, coherence, and historical/live controls. Reuse the established synchronized benchmark primitives; do not invent per-slot prefill aggregation.

## Read the local contract

Read [references/test-contract.md](references/test-contract.md) before planning a test. Read [references/host-profile.md](references/host-profile.md) when selecting binaries, model, devices, environment, or historical controls.

## Workflow

### 1. State the claim

Write one sentence describing what the test is trying to prove. Narrow the test to the changed mechanism. Do not use single-request speculative decode throughput to judge a scheduler mechanism when proposal acceptance is content-dependent.

Record:

- test mode;
- current server binary;
- speculative implementations and dynamic limits;
- server slots and simultaneous requests;
- prompt/decode token counts;
- batch/microbatch;
- KV layout and type;
- workload shape;
- closest historical control.

### 2. Select the mode

- **Proof of concept:** custom to the mechanism. Use the minimum repetitions and workload needed to prove that it exists and functions. State the custom protocol.
- **Quick and dirty:** exactly one complete warmup and one measured run. Use mid-workflow to catch obvious regressions or broken behavior.
- **Final testing:** exactly one complete warmup and three measured runs. Use medians for the headline and show every measured value.

Do not silently substitute another repetition protocol.

### 3. Determine commands before execution

Use `scripts/standard_server_test.py --action plan ...` when the established synchronized request shape applies. For a custom proof of concept, derive the server invocation from the same host profile and established server arguments.

Before running anything, show the user:

```text
Claim:
Protocol:
Server invocation:
Request/test invocation:
Historical comparison selected:
Why this comparison is closest:
```

Do not start a server until these are visible. Never stop or replace an unrelated running server or GPU workload. If the GPUs are occupied, provide the plan and wait.

### 4. Run the current build

Prefer synchronized concurrent release for multi-request throughput. Keep server capacity fixed when testing different active-request counts unless server-size scaling is itself the claim.

Use aggregate prefill:

```text
sum(actual prompt tokens) / (latest first token - synchronized release)
```

Use active decode:

```text
sum(actual generated tokens) / (latest completion - earliest first token)
```

Never sum or multiply reported per-slot prompt rates.

### 5. Assess coherence

Coherence is a sanity check, not a semantic conformance test.

Fail coherence for:

- server/backend crash;
- NaN or allocator/backend corruption signal;
- null or Unicode replacement characters;
- exact output leakage from another concurrent request;
- empty output or obvious repetitive token soup;
- failure to produce the requested forced token count when that count is part of the test.

Record as warnings, not failures:

- missing or mutated expected prose/sentinel;
- malformed reasoning tags;
- stylistic or factual differences;
- output that differs from another build but remains coherent.

Inspect a small local output sample for obvious token soup. Do not publish raw prompts or generated text in sanitized results.

### 6. Compare with ROCm YOLO before concurrency work

Select the closest retained historical result in this priority order:

1. same MTP/ngram implementation set;
2. same batch and microbatch;
3. same simultaneous request count/server shape;
4. same prompt and decode sizes;
5. same KV layout.

Use the retained aggregate package only as the first comparison. If the workload is not genuinely comparable, label it directional.

Run the pre-dynamic-speculation YOLO binary with the current test's exact protocol when any applies:

- comparable prefill differs by more than 5%;
- comparable decode differs by more than 10%;
- coherence differs;
- the closest historical record differs materially in workload shape;
- a regression/equivalence conclusion will be made.

Change only the binary and unsupported dynamic policy arguments for the live control. Keep model, speculation set, slots, active requests, prompt/decode sizes, batch/microbatch, KV, environment, warmup, measured count, seeds, and workload fixed.

### 7. Report

Always show this user-facing table:

| Build/test | Speculation | Prefill t/s | Decode t/s | Prefill size | Decode size | Batch/microbatch | Coherence |
|---|---|---:|---:|---:|---:|---:|---|

For final testing, use medians in the table and list all three measured prefill/decode values immediately below it. For quick tests, show the single measured values. For proof-of-concept tests, identify the aggregation used.

Then show the closest historical or live control and percentage differences. Distinguish:

- mechanism result;
- directional historical comparison;
- exact live equivalence/regression comparison.

Do not diagnose a root cause from throughput alone.

## Standard runner

Use:

```powershell
python skills/llamacpp-server-test/scripts/standard_server_test.py --help
```

The runner defaults to planning only. `--action run` performs the test after the plan has been shown. It writes command metadata, raw local artifacts, wave summaries, and `report.md` under the configured output directory.

During execution, the runner flushes phase changes immediately, emits a progress line every 15 seconds while server startup or a wave is running, and prints a complete metric row as soon as each warmup or measured wave finishes. Keep this output visible to the user; do not hide it behind a long blocking call. Change the cadence with `--progress-interval` when needed.

The runner supports the established synchronized completion workload. Keep genuinely custom proof-of-concept mechanics outside it, but follow the same command disclosure and report contract.
