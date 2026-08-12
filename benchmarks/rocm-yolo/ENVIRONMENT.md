# Test environment

## Hardware

- AMD Radeon RX 7900 XTX, `gfx1100`, 24 GiB
- AMD Radeon AI PRO R9700, `gfx1201`, 32 GiB
- Layer-split multi-GPU execution with the R9700 as the main GPU

## Software

- Windows
- ROCm 7.14
- Clang 23.0.0
- Ninja, Release configuration, shared libraries
- GPU targets: `gfx1100;gfx1201`

## Principal YOLO build configuration

```text
GGML_HIP=ON
GGML_HIP_MMQ_MFMA=ON
GGML_HIP_GRAPHS=OFF
GGML_CUDA_NO_PEER_COPY=ON
GGML_HIP_NO_VMM=ON
GGML_HIP_UNSAFE_MATH=OFF
GGML_HIP_EXPORT_METRICS=OFF
GGML_RPC=OFF
```

Runtime environment:

```text
ROCBLAS_USE_HIPBLASLT=0
LUCE_Q8_MEMO=1
```

For this R9700 + RX 7900 XTX machine, peer copy had to be compiled out. HIP
graphs and hipBLASLt were performance regressions in the tested serving
configuration. Those findings are machine- and workload-specific.

## Models and cache

Primary model:

- Qwen3.6 35B-A3B
- Q8_0 weights
- embedded MTP tensors where MTP was tested
- BF16 target and draft K/V cache
- flash attention enabled
- complete GPU layer offload

A Qwen3.6 27B Q8_0 model with BF16 KV was also used for a smaller speculative
decoding suite.

No model files are included in this repository.

## Compared builds

- Mainline commit `704485942ab54bbbbf1f241b3550ffba35f5f37e`
- Archived PR-26856 build
- YOLO performance build at `e422a519d`, including PR 26856 and the collected
  ROCm patch stack
- Unified-KV fix commit `40843ed0d`

The mainline and YOLO no-spec comparison used ROCm 7.14, the same two GPU targets,
HIP graphs off, peer copy off, BF16 KV and hipBLASLt off.
