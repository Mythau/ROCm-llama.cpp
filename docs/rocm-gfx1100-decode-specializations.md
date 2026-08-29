# ROCm gfx1100 decode specializations

This checkout contains the validated cumulative Qwen3.6 Q8 decode treatment
used by the retained 29 August 2026 runtime. It combines scheduler/transfer
timing work with three graph-selected gfx1100 kernel specializations.

## Runtime transfer and input preparation

- `GGML_SCHED_ASYNC_INPUTS=1` prepares eligible host inputs together for each
  backend split instead of synchronizing the destination independently for
  every small copy.
- `GGML_SCHED_CONSOLIDATE_HOST_INPUTS=1` extends that preparation to eligible
  non-weight host tensors whose producer has completed.
- `GGML_HIP_EVENT_STAGING=1` carries a cross-device tensor through one pinned
  host slot per source/destination pair. Source D2H completion orders the
  destination H2D with HIP events; slot reuse waits on the preceding upload.

These paths are opt-in. Their generic scheduler and copy paths remain the
fallback when the environment switches are absent or a transfer is ineligible.

## Exact gfx1100 decode paths

`cumulative-specializations.cuh` constructs one immutable plan from graph
topology before execution. All three paths require runtime RDNA3.0 and exact
shape, layout, alias, producer, and consumer relationships. The R9700/gfx1201
cannot select them.

1. **Row-owned QKV:** Q8_0 `2048 x 8192`, one activation column. One wave owns
   each output row while preserving the original eight partial sums and their
   addition order.
2. **Direct recurrent state:** for the single-sequence, single-token
   `[128,128,32,1]` state, the fused GDN reads and writes the selected persistent
   slot directly. Indexed, multi-sequence, rollback, and externally consumed
   gather cases retain the generic path.
3. **Split convolution:** the channels-major `[8192,3,1]` history and
   `[8192,1,1]` new input are consumed directly. One kernel computes the
   four-tap convolution and SiLU and writes the shifted three-row history,
   removing CONCAT materialization and its update copy.

## Validation record

The retained four-process cohort measured 11.205290898438 ms/token
(89.243555 token/s), versus 11.631954960938 ms/token (85.970072 token/s) for
the protected combined runtime. Fixed 32-token full logits were bit-identical:
7,946,240 floats with SHA-256
`0b41ac4772d8812401d38b85d9da9a8255c047a929a4f4f5e58df43b3ffa4414`.

The verification build selected every specialization 1,935 times on gfx1100
and zero times on gfx1201 during the 129-token run: 15 layers for every
recurring token. Sustained multi-token prefill selected none of them; only a
one-token tail can take the decode-shaped paths.

The complete measurements, build identities, architecture audit, and numeric
records remain under `2026-08-29/q8-cumulative-candidate` in the surrounding
runtime workspace.
