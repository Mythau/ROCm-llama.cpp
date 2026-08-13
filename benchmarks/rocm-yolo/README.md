# ROCm YOLO benchmark package

This directory contains a sanitized subset of the local validation performed for
the `rocm-yolo` branch on 2026-08-12 and 2026-08-13. It contains aggregate measurements and no
model outputs, prompts, server logs, binaries, model files, credentials, or
machine-local paths.

## Headline results

- A like-for-like, single-request 8K no-spec prefill measured **4,231.5 t/s** on
  the archived mainline build and **4,890.8 t/s** on the YOLO build. The YOLO
  result is **15.6% faster**. The mainline value is the mean of three measured
  runs; the YOLO value is one warm run and should be repeated independently.
- Four simultaneous 8K prompts at batch 8192 / microbatch 1024 reached an
  aggregate prefill mean of **4,735.7 t/s** across three measured waves.
- The dynamic speculative scheduler matched its fixed-mode controls: **-0.14%**
  prefill at one active request, **-2.64%** at two, and **+1.06%** at four.
  With all speculation gated at four requests, decode was **2.08%** below a
  true no-spec server.
- Dynamic cache restoration retained MTP after a synchronized solo restore
  (**8,447 cached / 1 evaluated**) and retained the target hit without
  promoting MTP for an occupancy-two target-only entry (**8,188 / 4**).
- The unified-KV restore correction reduced restored-prompt TTFT from
  **56.89 seconds** to **2.81 seconds** for four cached 8K requests while
  retaining the same 32,752 cached / 16 evaluated prompt-token accounting.

The single-request and four-request prefill figures use different protocols and
are presented separately. No concurrency scaling factor is applied to either.

## Contents

- [ENVIRONMENT.md](ENVIRONMENT.md): tested hardware, toolchain and settings.
- [RESULTS.md](RESULTS.md): prefill, decode, speculation and concurrency tables.
- [UNIFIED-KV.md](UNIFIED-KV.md): the cache-restore regression and patched result.
- [METHODOLOGY.md](METHODOLOGY.md): workload and aggregate metric definitions.
- [raw/aggregates.json](raw/aggregates.json): exact sanitized aggregate values.

## Scope

These numbers describe one Windows dual-GPU system running Qwen3.6 Q8_0 models
with BF16 KV. They are evidence for this configuration, not universal ROCm
claims. Results should be reproduced on other hardware before being generalized.
