# Cohort Batching Rollback Runbook

Operator-facing runbook for per-phase reverse-order rollback of the cohort-batching phased implementation. This document does not wire CI or automation.

## Enforceable rule

Rollback must proceed in **strict reverse phase order** (highest landed phase first). Reverting a lower phase while any higher phase remains landed is prohibited. Before starting any rollback, identify the highest currently-landed phase and begin there.

## Do not proceed if

- A higher-numbered phase is still landed and you have not first reverted it. Example: do not attempt to revert Phase 3 while Phase 4 or Phase 5 source changes remain applied.
- Any grep or build verification command below does not produce the expected result after reversion; the tree is in an inconsistent state and manual inspection is required before continuing.
- The working tree contains uncommitted source changes unrelated to the phase being reverted. Stash or commit unrelated work first.

---

## Phase 8 rollback

Phase 8 is validation-only with no architecture commit. No rollback required. Clean up any Phase 8 test artefacts or temporary benchmark configs.

**Verification:** the committed tree matches the Phase 7 final state. `git log --oneline -1` shows the Phase 7 commit or a clean checkout state.

---

## Phase 7 rollback

Revert Phase 7 to hide the feature while retaining the controller architecture.

**Operation:** undo the Phase 7 commit(s) that consumed resolved options, exposed server logs/metrics/props/docs, and added paired option fields/parsing/environment wiring. Restore the Phase 6 state where cohort mode is inaccessible behind configured `E`/`X` thresholds and no user-facing option exposes the feature.

**Verification:**
- `rg -n "cohort.*option|enable.*cohort|--cohort" common/`: no user-facing option or argument parsing exposes cohort mode.
- `rg -n "cohort.*prometheus|cohort.*metric" tools/server/`: no cohort-specific Prometheus metrics remain.
- `rg -n "iteration_id|cohort_id" tools/server/` may still appear in controller/execution code (Phase 6 artefact) but must not appear in Prometheus label registrations.
- Server help output (`--help`) shows no cohort-related arguments.

---

## Phase 6 rollback

Revert Phase 6 before Phase 5.

**Operation:** undo all cohort runtime integration: `COHORT_ENTRY_DRAIN`, `COHORT_INTERMISSION`, `COHORT_FORM`, `COHORT_PREFILL`, `COHORT_DECODE` phase transitions, mutable cohort lifecycle state, threshold/hysteresis decisions, cohort binding, intermission quota state, and Phase 1 phase/config/cohort declarations made executable.

**Verification:**
- `rg -n "COHORT_ENTRY_DRAIN|COHORT_INTERMISSION|COHORT_FORM|COHORT_PREFILL|COHORT_DECODE" inference/`: no executable cohort phase transitions remain. Phase 1 dormant vocabulary declarations are acceptable if present but must not be referenced by any executable path.
- `rg -n "active_cohort|cohort_id|formation_assessment|entry_intent|intermission_task" inference/control/`: no mutable cohort lifecycle state remains.
- `rg -n "ENTRY_DRAIN|INTERMISSION" tools/server/`: no server code references cohort phase transitions.
- NORMAL-only server regression tests pass.

---

## Phase 5 rollback

Revert Phase 5 before Phase 4 or Phase 3.

**Operation:** restore both legacy MTP activation call sites. Undo the single post_decode generating scan owned by control. Restore independent activation decisions at the pre_decode maintenance pass and the post_decode prompt-completion transition.

**Verification:**
- `rg -n "try_activate_deferred_mtp" tools/server/server-context.cpp`: both legacy call sites are live (one pre_decode maintenance pass, one post_decode prompt-completion transition); no control-committed activation path exists.
- `rg -n "mtp_activation_proposal|mtp_activation_commit" inference/`: no control types for MTP activation remain.
- `rg -n "generating scan|post_decode.*boundary.*periodic" tools/server/server-context.cpp`: no unified generating scan exists; the two independent call sites are the sole activation timing.
- NORMAL deferred-MTP behavior matches the Phase 4 frozen baseline.

---

## Phase 4 rollback

Revert Phase 4 before reverting Phase 3.

**Operation:** undo queue-owned lease/candidate-set selection, atomic admission with exact placement plan and control-owned formation scope, and the `admission_adapter` apply transaction. Restore pre-Phase-4 queue-to-slot assignment and cancellation mechanics.

**Verification:**
- `rg -n "lease_id|admission_adapter|admission_commit|formation_assessment" inference/`: no admission-commit types or adapter interfaces remain.
- `rg -n "admission_adapter|admission_commit" tools/server/`: no server-side admission-adapter integration remains.
- `rg -n "cohort_id" inference/admission/ tools/server/`: queue lease values do not carry a `cohort_id`; neither NORMAL admission nor an aborted lease allocates one.
- Legacy queue-to-slot assignment and cancellation paths are restored and pass existing tests.

---

## Phase 3 rollback

Revert Phase 3 to the Phase 2 legacy seam. After later phases land, rollback must proceed in reverse order first.

**Operation:** restore the legacy planner, shadow comparator, and categorical target-scheduling interpretation. Undo the first mutable `inference::control::controller` and NORMAL iteration protocol. Restore `make_legacy_intent()`, `finalize_legacy_target_manifest()`, and the non-applying comparator as the sole scheduling authority.

**Verification:**
- `rg -n "SLOT_STATE_GENERATING|SLOT_STATE_DONE_PROMPT" tools/server/server-context.cpp`: legacy categorical scheduling branches are restored; the Phase 3/4 delete-list gate no longer applies.
- `rg -n "target_batch_commit|target_batch_outcome|iteration_completion" tools/server/`: the legacy target-manifest path is the sole authority; no control-owned iteration protocol or command is the caller.
- `rg -n "make_legacy_intent|finalize_legacy_target_manifest" tools/server/`: the legacy seam wrappers exist and are the active scheduling path.
- `inference::control::controller` either does not exist or is dormant (Phase 1 contract-only state).
- NORMAL target manifests equal Phase 0 fixtures.

---

## Phase 2 rollback

Revert Phase 2 while Phase 1 remains dormant.

**Operation:** undo the mechanical execution extraction. Restore `server_context::update_slots()` to its pre-extraction state. Remove the `server_inference::snapshot_reader`, the diagnostics-only comparator, and the typed `server_execution::executor` façade.

**Verification:**
- `rg -n "snapshot_reader|server_execution::executor|iteration_id" tools/server/server-context.cpp`: no extracted snapshot reader or executor façade remains; `update_slots()` is a single monolithic body with no extracted interfaces.
- `rg -n "prepared_decode_outcome|prompt_reconciliation_outcome|target_manifest" tools/server/`: no iteration-tagged outcome types reach the server pump.
- `rg -n "iteration_completion" tools/server/`: no iteration-closure boundary exists; the legacy post_decode/maintenance loop is the sole pump.
- Legacy NORMAL behavior is byte-for-byte identical to the Phase 0 baseline.

---

## Phase 1 rollback

Revert the additive contract/test commit. No runtime authority or existing queue declaration moved in this phase.

**Operation:** remove the dormant server-local vocabulary (`inference::identity`, `inference::profile`, `inference::control`, `inference::admission`, `inference::batching` types) and the stable leaf-pure proposal calculation tests.

**Verification:**
- `rg -rn "inference::identity|inference::profile|inference::control|inference::admission|inference::batching" inference/ tools/server/`: no cohort-batching vocabulary types remain.
- `rg -n "stream_key|cohort_id|iteration_id" inference/`: no value-type definitions remain.
- `rg -n "cohort_batching" tools/server/tests/`: no cohort-batching test targets remain.
- Release CPU `llama-server` compiles with no `inference::` cohort-batching headers.
