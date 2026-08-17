# ROCm YOLO test host

## Contents

- Hardware and runtime
- Canonical binaries
- Model and server settings
- Historical results

## Hardware and runtime

- RX 7900 XTX (`gfx1100`, 24 GiB) plus R9700 (`gfx1201`, 32 GiB).
- Layer split across `ROCm0,ROCm1`; R9700 is main GPU 1.
- ROCm 7.14, Clang 23, Release shared build.
- Peer copy compiled out on this machine.
- HIP graphs off and hipBLASLt off; both regressed this workload.
- BF16 target/draft KV, flash attention, complete layer offload.

Runtime environment:

```text
ROCBLAS_USE_HIPBLASLT=0
LUCE_Q8_MEMO=1
```

## Canonical binaries

Current dynamic build default:

```text
C:\AI\runtimes\llamacpp\2026-08-12\build\llamacpp-yolo-dynamic-spec-rocm714-gfx1100-gfx1201-hipgraphs-off\bin\llama-server.exe
```

Pre-dynamic-speculation ROCm YOLO control:

```text
C:\AI\runtimes\llamacpp\2026-08-12\build\llamacpp-yolo-allpatches-rocm714-gfx1100-gfx1201-hipgraphs-off\bin\llama-server.exe
```

Always hash the selected executable and record the full path. A rebuilt binary at the same path is a different test identity.

## Model and server settings

Primary model:

```text
C:\AI\models\Qwen3.6-35B-A3B-Q8_0-mtp.gguf
```

Production-like four-slot workload:

- server parallel 4;
- total context 50,176;
- prompt 8,192 and generation 4,096 per request;
- speculative headroom 256 tokens/slot;
- partitioned KV and continuous batching;
- batch 8,192 / microbatch 1,024.

Broader historical concurrency workload:

- prompt 8,192 / generation 4,096;
- batch 2,048 / microbatch 512;
- partitioned KV;
- 2, 4, or 8 synchronized requests.

## Historical results

Canonical retained aggregates:

```text
benchmarks/rocm-yolo/raw/aggregates.json
```

Methodology and interpretation:

```text
benchmarks/rocm-yolo/METHODOLOGY.md
benchmarks/rocm-yolo/RESULTS.md
benchmarks/rocm-yolo/ENVIRONMENT.md
```

The synchronized benchmark implementation is outside the source checkout at:

```text
C:\AI\runtimes\llamacpp\2026-08-12\concurrency-sync-bench.py
```

The skill runner imports its established prompt construction, synchronized release, server arguments, coherence checks, timing, and log validation.
