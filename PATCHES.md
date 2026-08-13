# Explicit patch manifest

This is the authoritative inventory of custom code changes in the `rocm-yolo`
branch relative to base commit `6e62ba538` (`llama.cpp` build-era mainline).

The branch is an aggregate experiment. Some entries are direct cherry-picks,
some are squashed imports, and some are local adaptations. Those distinctions
are explicit below. A label does not imply that the original author supports or
maintains this fork.

## Label definitions

Provenance:

- **UPSTREAM-PR** — imported from a numbered `ggml-org/llama.cpp` pull request.
- **AMD-FORK-PR** — imported from a numbered `AMD-Ecosystem/llama.cpp` pull request.
- **EXTERNAL-BRANCH** — imported from a named third-party research branch.
- **LOCAL-PORT** — adapted locally from external work; not a mechanical cherry-pick.
- **LOCAL-FIX** — developed specifically for this aggregate branch.

Applicability:

- **RDNA3** — relevant to `gfx1100` / RX 7900 XTX.
- **RDNA3.5** — relevant to gfx11.5-class kernels; may compile but not execute on
  the tested `gfx1100` or `gfx1201` devices.
- **RDNA4** — relevant to `gfx1201` / R9700.
- **Q8**, **MOE**, **PREFILL**, **DECODE**, **FA**, **MULTI-STREAM**, **KV-RESTORE**
  describe the path or workload touched.
- **BUILD-SAFETY** changes compilation or numerical/correctness defaults.

Cherry-picking should follow the order shown within each series unless an entry
is explicitly marked standalone.

Patch IDs follow the code-commit order in the branch. Sections group related
work by subsystem, so a later compatibility patch such as P25 is documented
beside the earlier Lucebox patch on which it depends.

## Series A — native BF16 Flash Attention tile stack

### P01 — PR 26856 native BF16 tile stack

- **Commit:** `65f78e540`
- **Labels:** `UPSTREAM-PR`, `RDNA3`, `RDNA4`, `BF16`, `FA`, `PREFILL`
- **Source:** [ggml-org/llama.cpp PR 26856](https://github.com/ggml-org/llama.cpp/pull/26856)
- **Original series author:** Stew Forster
- **Import form:** seven source commits squashed into one local aggregate commit
- **Touches:** BF16 K/V tile loading, BF16 KQ storage, packed BF16 dot path,
  dispatch and backend-operation tests
- **Dependency:** base for this branch's BF16 FA experiments
- **Observed locally:** the archived PR-only build improved single-request 8K
  no-spec prefill from 4,231.5 to 4,297.0 t/s; the complete YOLO branch contains
  many additional changes, so its gain must not be attributed solely to P01

## Series B — AMD WMMA head-dimension work

Source branch:
[srgtuszy/llama.cpp `opt/rdna-wmma-dkq256`](https://github.com/srgtuszy/llama.cpp/tree/opt/rdna-wmma-dkq256).

### P02 — bypass LDS staging for K/V at DKQ greater than 128

- **Commit:** `7536612d7`
- **Labels:** `EXTERNAL-BRANCH`, `RDNA3`, `RDNA4`, `F16`, `FA`, `PREFILL`
- **Original author:** Michal Tuszynski
- **Dependency:** first patch in P02-P04
- **Scope:** changes the AMD WMMA F16 Flash Attention path; it is not the PR-26856
  native-BF16 tile path

### P03 — enable MMA F16 Flash Attention through DKQ 256

- **Commit:** `231a71131`
- **Labels:** `EXTERNAL-BRANCH`, `RDNA3`, `RDNA4`, `F16`, `FA`, `HEAD-DIM-256`
- **Original author:** Michal Tuszynski
- **Dependency:** P02
- **Scope:** extends AMD WMMA F16 dispatch to head dimensions up to 256

### P04 — fix WMMA tile-mask write-after-read race

- **Commit:** `e929fa060`
- **Labels:** `EXTERNAL-BRANCH`, `RDNA3`, `RDNA4`, `F16`, `FA`, `CORRECTNESS`
- **Original author:** Michal Tuszynski
- **Dependency:** P02-P03
- **Evidence in source commit:** 14,600 accumulated `FLASH_ATTN_EXT` backend-op
  cases passed on `gfx1201`

These three patches are included in the aggregate build, but they should not be
advertised as improving BF16-KV workloads mechanically. They target the F16 AMD
WMMA path.

## Series C — HIP build and numerical safety

### P05 — make unsafe floating-point reassociation opt-in

- **Commit:** `7c30c8aba`
- **Labels:** `AMD-FORK-PR`, `BUILD-SAFETY`, `MTP`, `CORRECTNESS`
- **Source:** [AMD-Ecosystem/llama.cpp PR 81](https://github.com/AMD-Ecosystem/llama.cpp/pull/81)
- **Original author:** Jim Wu
- **Standalone:** yes
- **Effect:** adds `GGML_HIP_UNSAFE_MATH`, default `OFF`; avoids enabling
  `-funsafe-math-optimizations` unconditionally
- **Reason:** reassociated reductions had produced greedy/MTP divergence on an
  RDNA3.5 test system

## Series D — MMVQ/MMQ and routed-MoE tuning

### P06 — dynamic MMVQ warp count for MoE matrix widths

- **Commit:** `9355cf9e5`
- **Labels:** `UPSTREAM-PR`, `MOE`, `MMVQ`, `RDNA3`, `RDNA4`
- **Source:** [ggml-org/llama.cpp PR 20831](https://github.com/ggml-org/llama.cpp/pull/20831)
- **Original author:** kangletian
- **Standalone:** generally, subject to source-version conflicts

### P07-P09 — PR 26284 RDNA MMQ configuration series

- **Commits:**
  - `99fbf4886` — RDNA3/RDNA4 MMQ configuration tuning
  - `a81645597` — RDNA3 MoE-regression correction
  - `38b4ffe86` — RDNA3 Q2_0 tuning
- **Labels:** `UPSTREAM-PR`, `RDNA3`, `RDNA4`, `MMQ`, `MOE`; P09 also `Q2_0`
- **Source:** [ggml-org/llama.cpp PR 26284](https://github.com/ggml-org/llama.cpp/pull/26284)
- **Original author:** itterative
- **Dependency:** apply P07, P08 and P09 in order
- **Test relevance:** P07/P08 are relevant to the tested mixed `gfx1100` and
  `gfx1201` build; P09 is compiled but the principal public benchmarks use Q8_0

### P10-P14 — PR 24546 routed-MoE column-selection series

- **Commits:**
  - `72b72b0e8` — routed-MoE `ncols_picker` selection
  - `d472654f2` — extend the policy to CDNA, RDNA2 and RDNA4
  - `8695b39e3` — retain NVIDIA and Volta support
  - `fc1a828cc` — move architecture thresholds into MMQ configuration
  - `85a929a5f` — replace the threshold with `use_typical_moe_ncols`
- **Labels:** `UPSTREAM-PR`, `MOE`, `MMQ`, `RDNA3`, `RDNA4`, `MULTI-ARCH`
- **Source:** [ggml-org/llama.cpp PR 24546](https://github.com/ggml-org/llama.cpp/pull/24546)
- **Original author:** ravel7524
- **Dependency:** one evolving five-commit series; apply in order

## Series E — Lucebox-derived Q8 and graph work

Primary external repository:
[Luce-Org/lucebox-ggml](https://github.com/Luce-Org/lucebox-ggml).

### P15 — adapt Lucebox RDNA MMQ Q8 tuning to split architecture configs

- **Commit:** `8dad7835a`
- **Labels:** `LOCAL-PORT`, `RDNA4`, `Q8`, `MMQ`, `PREFILL`
- **Local porter:** Codex Build
- **Provenance:** derived from Lucebox RDNA MMQ experiments, including vectorized
  Y-tile loading and reduced Q8_0 launch-bound occupancy; adapted to the current
  split `mmq-config-rdna4.cuh` layout
- **Not a direct cherry-pick:** yes; attribution must not be inferred from the
  local commit author field alone
- **Dependency:** P07-P14 establish the configuration layout it modifies

### P16 — stripped Q8_1 activation memo port

- **Commit:** `a80045642`
- **Labels:** `LOCAL-PORT`, `Q8`, `MMVQ`, `DECODE`, `ENV-GATED`
- **External source commit:** Lucebox `ac06e5431` by mrciffa
- **Local change:** ports only the `LUCE_Q8_MEMO` activation-reuse mechanism and
  omits unrelated instrumentation and profiling controls
- **Activation:** `LUCE_Q8_MEMO=1`

### P17 — extend Q8_1 activation memo to `MUL_MAT_ID`

- **Commit:** `a7d370523`
- **Labels:** `EXTERNAL-BRANCH`, `Q8`, `MOE`, `DECODE`
- **Original author:** dusterbloom
- **Dependency:** P16
- **Effect:** makes the memo cover MoE gate/router/shared-expert
  `MUL_MAT_ID` calls

### P18 — permit graph capture for MMQ `MUL_MAT_ID`

- **Commit:** `65fd9c751`
- **Labels:** `EXTERNAL-BRANCH`, `CUDA-GRAPH`, `MOE`, `MMQ`
- **Original author:** mrciffa
- **Dependency:** current MMVQ/MMQ dispatch rules
- **Test relevance:** compiled into the aggregate tree but inactive in the
  principal public build because `GGML_HIP_GRAPHS=OFF`

### P25 — update the Lucebox graph gate for the current batch-limit symbol

- **Commit:** `e422a519d`
- **Labels:** `LOCAL-PORT`, `BUILD-COMPATIBILITY`, `CUDA-GRAPH`, `MOE`
- **Local porter:** Codex Build
- **Dependency:** P18
- **Effect:** adapts P18 from the older `MMVQ_MAX_MOE_BATCH_SIZE` spelling to
  the current `MMVQ_MAX_BATCH_SIZE`
- **Test relevance:** inactive in the principal graphs-off build

## Series F — Qwen hybrid/delta-net kernels

### P19-P20 — Qwen3.6 convolution-layout series

- **Commits:**
  - `a55296c95` — force contiguous conv-state concat input
  - `484c078d4` — add channels-major SSM convolution and remove the transpose
- **Labels:** `AMD-FORK-PR`, `QWEN-HYBRID`, `PREFILL`, `RDNA3`, `RDNA4`
- **Source:** [AMD-Ecosystem/llama.cpp PR 52](https://github.com/AMD-Ecosystem/llama.cpp/pull/52)
- **Original author:** Robert Esclapez Garcia
- **Dependency:** apply P19 then P20; P20 supersedes part of P19 while retaining
  the causal progression and test coverage

### P21 — fused chunked gated-delta-net kernel

- **Commit:** `26c8300f3`
- **Labels:** `AMD-FORK-PR`, `RDNA3.5`, `QWEN-HYBRID`, `PREFILL`, `GDN`
- **Source:** [AMD-Ecosystem/llama.cpp PR 54](https://github.com/AMD-Ecosystem/llama.cpp/pull/54)
- **Original author:** Robert Esclapez Garcia
- **Execution scope:** explicitly gated to RDNA3.5 in the source commit; included
  in the multi-architecture build but not claimed as the cause of gains on the
  tested `gfx1100`/`gfx1201` pair
- **Activation:** enabled by default where eligible;
  `GGML_CUDA_GDN_CHUNKED=0` disables it

## Series G — multi-stream correctness and shared-expert overlap

### P22-P24 — AMD-Ecosystem multi-stream/shared-expert series

- **Commits:**
  - `b79e3a5be` — honor the active stream and isolate library handles
  - `a4a27ece2` — isolate concurrent-branch scratch allocation
  - `1f9ddc5ab` — overlap the MoE shared expert on an auxiliary stream
- **Labels:** `AMD-FORK-PR`, `MULTI-STREAM`, `MOE`, `CORRECTNESS`, `DECODE`
- **Source:** [AMD-Ecosystem/llama.cpp PR 36](https://github.com/AMD-Ecosystem/llama.cpp/pull/36)
- **Original author:** Robert Esclapez Garcia
- **Dependency:** P22 and P23 are correctness prerequisites for P24
- **Scope:** P24 is decode-only, single-GPU and gated behind
  `GGML_CUDA_GRAPH_OPT`; it is not the mechanism used to span the two tested
  GPUs and may be inactive under the documented graphs-off configuration

## Series H — unified-KV restore

### P26 — prefer contiguous placement during KV state restore

- **Commit:** `40843ed0d`
- **Labels:** `LOCAL-FIX`, `KV-RESTORE`, `UNIFIED-KV`, `MULTI-GPU`, `ROCM`
- **Author:** Codex Build, based on local source/log diagnosis
- **Standalone:** yes against a compatible `llama-kv-cache.cpp`
- **Effect:** request contiguous restored-cell placement first, log the selected
  placement, and fall back to the existing scattered allocator if necessary
- **Measured result:** four-request restored TTFT fell from 56.89 seconds to
  2.81 seconds with identical 32,752 cached / 16 evaluated token accounting
- **Remaining limitation:** when no sufficiently large contiguous range exists,
  the old scattered synchronous-transfer path remains possible

## What is not implemented

The following researched items are not patches in the current public branch:

- an administrative cache kill switch;
- a general multi-agent/job scheduler;
- coalesced or asynchronous scattered KV restoration;
- ROCWMMA BF16-cache replacement work;
- TurboQuant;
- profiling/instrumentation from the original Lucebox aggregate commit.

## Series I — dynamic speculative admission

### P27 — occupancy-driven per-request MTP/ngram policy

- **Commit:** this feature commit
- **Labels:** `LOCAL-FEATURE`, `SERVER`, `SPECULATIVE`, `MTP`, `NGRAM`, `PROMPT-CACHE`
- **Author:** Codex Build, based on local design, source tracing and benchmark validation
- **Standalone:** no; this is a coordinated common/server/cache change
- **Effect:** assigns MTP/ngram eligibility at request admission from occupied
  stream count, applies sticky demotion, filters MTP/ngram execution, switches
  target NextN per exact batch view and preserves truthful target-only versus
  synchronized-MTP cache state
- **CLI:** `--spec-active-limit TYPE=N,...`
- **Validated policy:** `draft-mtp=1,ngram-mod=2` on a four-slot Q35 server
- **Supported dynamically:** MTP and all n-gram implementations
- **Static-only:** draft-simple, Eagle3, DFlash and DSpark
- **Details:** [`DYNAMIC_SPECULATION_PATCH_NOTES.md`](DYNAMIC_SPECULATION_PATCH_NOTES.md)

## Minimal cherry-pick guidance

- Unified-KV restore only: P26.
- PR-26856 BF16 FA only: P01.
- RDNA WMMA F16 head-dimension work: P02-P04.
- PR-26284 RDNA MMQ tuning: P07-P09.
- Routed-MoE MMQ policy: P10-P14.
- Q8 activation reuse: P16-P17, with `LUCE_Q8_MEMO=1`.
- Qwen hybrid conv layout: P19-P20.
- Multi-stream/shared-expert series: P22-P24 in order.
- Dynamic speculative admission: P27 as one coordinated feature commit.

Expect conflicts when applying these commits to newer llama.cpp revisions. The
aggregate branch is the tested combination; individual cherry-picks still need
their own compilation, backend-operation and inference-coherence validation.
