# Experimental ROCm patch fork

This branch is a practical patch shelf built for local multi-GPU llama.cpp
experimentation. It combines ROCm/RDNA performance work, Q8 and MoE tuning, and
a unified-KV prompt-cache restore correction in one source tree.

It is published so other people can run it, inspect it, or cherry-pick individual
commits. It is expected to be minimally maintained. There are no release builds,
support guarantees, compatibility promises, or claim that every patch is
appropriate for upstream llama.cpp.

That's a nice way of saying this is LLM slop and I'm proud of it. It's a 
collection of various patches & ROCm performance improvements found spread
out all over github.

## Tested hardware and software

The current branch was built and exercised on Windows with:

- AMD Radeon RX 7900 XTX, `gfx1100`, 24 GiB
- AMD Radeon AI PRO R9700, `gfx1201`, 32 GiB
- ROCm 7.14
- Clang 23.0.0
- Ninja, Release configuration, shared libraries
- Qwen3.6 27B and 35B-A3B Q8_0 weights with BF16 KV
- multi-GPU layer splitting across both devices

Other GPUs, ROCm versions, operating systems, models, quantizations, and cache
types have not been established by this local test campaign.

Sanitized results and methodology are available in
[`benchmarks/rocm-yolo`](benchmarks/rocm-yolo/README.md).

## What is in the branch

The commit history intentionally preserves the changes as separate commits so
they can be reviewed or cherry-picked independently. The main groups are:

- the native BF16 tile stack from llama.cpp PR 26856;
- AMD WMMA Flash Attention changes for larger head dimensions;
- RDNA 3 and RDNA 4 MMQ/MoE tuning;
- Lucebox-derived Q8 MMQ and Q8_1 activation reuse changes;
- fused and layout-tuned Qwen hybrid-model operations;
- multi-stream correctness and overlap changes;
- a unified-KV prompt-cache restore fix that prefers contiguous destination
  cells before falling back to scattered placement;
- occupancy-driven per-request MTP/ngram admission for multi-slot servers.

Every custom code commit is listed in [`PATCHES.md`](PATCHES.md) with explicit
provenance and applicability labels. The labels distinguish official llama.cpp
PR imports, AMD-Ecosystem fork imports, external research branches, local ports
and local fixes; they are not merely descriptive patch names.

The history is the authoritative patch inventory. This is an aggregate branch,
not a claim of original authorship over patches sourced or adapted from other
contributors. Retained commit messages provide the most useful provenance
currently available in this experimental tree.

## Unified-KV restore correction

Commit `40843ed0d` changes KV state restoration to request a contiguous range
first. If no contiguous range is available, it retains the existing scattered
placement fallback.

This addresses a severe ROCm restore pathology observed after unified-KV cache
reuse. Scattered placement caused state restoration to degrade into a very large
number of small synchronous backend transfers. In the observed 8,447-token
Qwen3.6 35B case, the slow path implied 168,940 individual K/V tensor writes.

This patch improves placement; it does not redesign cache eviction, make state
restoration asynchronous, guarantee contiguous capacity, or physically compact
an already-fragmented KV cache.

## Reproducing the tested build

The successful graphs-off build used the effective configuration below. Adjust
the compiler and Ninja paths for your installation.

```powershell
cmake -S . -B build-rocm-yolo -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DBUILD_SHARED_LIBS=ON `
  -DGGML_HIP=ON `
  -DAMDGPU_TARGETS="gfx1100;gfx1201" `
  -DGPU_BUILD_TARGETS="gfx1100;gfx1201" `
  -DGGML_HIP_MMQ_MFMA=ON `
  -DGGML_HIP_GRAPHS=OFF `
  -DGGML_CUDA_NO_PEER_COPY=ON `
  -DGGML_HIP_NO_VMM=ON `
  -DGGML_HIP_UNSAFE_MATH=OFF `
  -DGGML_HIP_EXPORT_METRICS=OFF `
  -DGGML_RPC=OFF

cmake --build build-rocm-yolo --config Release --parallel 32
```

The tested runtime set:

```powershell
$env:ROCBLAS_USE_HIPBLASLT = "0"
$env:LUCE_Q8_MEMO = "1"
```

For the tested R9700 + RX 7900 XTX machine, these are important operational
requirements rather than incidental build choices:

- peer copy must be disabled at compile time with
  `GGML_CUDA_NO_PEER_COPY=ON` or it produces token soup;
- HIP graphs (`GGML_HIP_GRAPHS=ON`) produced a performance regression, so the
  tested server build uses `GGML_HIP_GRAPHS=OFF`;
- hipBLASLt selected through `ROCBLAS_USE_HIPBLASLT=1` produced a performance
  regression, so the tested runtime uses `ROCBLAS_USE_HIPBLASLT=0`.

These results describe this particular mixed-GPU machine and its tested Qwen
Q8/BF16-KV workloads. They are not asserted as universal defaults for every AMD
GPU, ROCm release, model, or quantization. Benchmark both settings for your own
hardware and workload.

## Dynamic speculative decoding

The branch supports a server-wide occupied-stream policy for MTP and n-gram
implementations. The tested four-slot invocation adds:

```text
--spec-type draft-mtp,ngram-mod
--spec-active-limit draft-mtp=1,ngram-mod=2
```

This admits MTP plus ngram at one active request, ngram only at two, and neither
at three or four. Demotion is sticky for the current request; later requests are
evaluated afresh. Cache restoration retains synchronized MTP only when target,
draft and serialized boundary state match. See
[`DYNAMIC_SPECULATION_PATCH_NOTES.md`](DYNAMIC_SPECULATION_PATCH_NOTES.md) for
the exact implementation, validation and limitations.

## Important limitations

- The branch is intentionally experimental and may diverge from upstream.
- It was assembled as a custom performance build, not as a polished product.
- HIP graphs and hipBLASLt were measured regressions on the tested machine.
- Peer copy had to be compiled out for the tested R9700 + RX 7900 XTX pairing.
- The unified-KV fix has strong measured evidence on the tested configuration,
  but it is not a general KV-cache compaction algorithm.
- Speculative MTP carries its own auxiliary context and state. The dynamic patch
  serializes the required boundary state for aligned restores, but not every
  arbitrary rewind or model-draft implementation is supported.
- Occupancy-driven per-request speculative admission is implemented; a broader
  multi-agent/job scheduler is not.
- No binaries, model files, benchmark dumps, or ROCm runtime redistributables are
  included by this documentation commit.

## Intended use

Use the complete branch if its hardware and workload assumptions match yours.
Otherwise, inspect the history and cherry-pick only the changes you understand
and can validate. In either case, compare against a contemporary upstream build
and test output coherence as well as throughput.

Bug reports and patches may be useful to other users, but publication of this
branch does not imply an ongoing maintenance or support commitment.
