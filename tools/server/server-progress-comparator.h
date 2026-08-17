#pragma once

// Diagnostics-only shadow evidence for the Phase 2 legacy seam. Derives
// projected pending work from a post-reconciliation snapshot and compares it
// with the finalized legacy target manifest plus the complete outcome.
// Never mutates slots, runtime, control, fairness cursors, legacy intent, or
// the manifest; never publishes a projection while an iteration is incomplete.
// Compiled behind LLAMA_COHORT_DIAGNOSTICS so no production path can invoke it
// as a scheduler. Temporary seam, deleted with the legacy planner in Phase 3.

#include "server-execution-outcome.h"
#include "server-inference-snapshot.h"
#include "server-legacy-intent.h"

#include <cstddef>
#include <optional>
#include <string>
#include <vector>

namespace server_inference {

struct pending_work_item {
    enum class category {
        PROMPT,
        DRAFT,
        REPLAY,
        SAMPLED_INPUT,
    };

    category                        kind;
    inference::identity::stream_key stream;
    int32_t                         logical_rows;
};

struct projected_pending_work {
    inference::identity::iteration_id iteration;
    std::vector<pending_work_item>    items;
};

struct manifest_row_provenance {
    enum class source {
        PENDING_WORK,
        UNEXPLAINED,
    };

    std::size_t row_index;
    source      provenance;
    std::size_t pending_item_index;
};

struct outcome_membership_evidence {
    std::size_t result_index;
    bool        manifest_member;
};

struct progress_comparison_report {
    bool                                      published;
    projected_pending_work                    pending;
    std::vector<manifest_row_provenance>      row_coverage;
    std::vector<outcome_membership_evidence>  outcome_coverage;
};

// Step 11: prepared-live-stream invariant audit. Diagnostic-only; asserts the
// four prepared-live-stream invariants as evidence, never enforcing them.
struct prepared_live_invariant_report {
    bool all_prepared_in_manifest = true;
    bool no_manifest_omission     = true;
    bool bulk_draft_only_intent    = true;
    std::vector<std::string> findings;
};

// Step 11: output/logit and NextN rows match target-manifest block membership.
struct output_nextn_membership_report {
    bool all_rows_explained = true;
    std::vector<std::string> findings;
};

// Post-reconciliation pending-work derivation. PROMPT streams carry prompt
// decode work; DONE_PROMPT_BEFORE_SAMPLE and GENERATING with pending sampled
// input carry sampled-input work; GENERATING additionally carries prepared
// speculative extent as draft work and mandatory replay rows as replay work.
// STARTED/WAIT_OTHER streams carry no item: their admission is not yet
// materialized in the post-reconciliation snapshot.
projected_pending_work project_pending_work(
        const std::vector<stream_snapshot> & post_reconciliation);

class progress_comparator {
public:
    progress_comparator() = default;

    progress_comparison_report compare(
            const std::vector<stream_snapshot> & post_reconciliation,
            const server_execution::legacy_target_manifest & manifest,
            const std::optional<server_execution::target_batch_outcome> & complete_outcome) const;

    // Prepared-live-stream invariants (Step 11). Shadow evidence only:
    //  - every prepared_decode_outcome maps to a manifest block;
    //  - every manifest block with a prepared stream has a matching outcome;
    //  - no manifest block's draft membership exceeds the legacy intent's
    //    drafting set (bulk-draft only the selected set).
    prepared_live_invariant_report audit_prepared_live(
            const std::vector<server_execution::prepared_decode_outcome> & prepared,
            const server_execution::legacy_intent & intent,
            const server_execution::legacy_target_manifest & manifest) const;

    // Output/logit and NextN rows must match block membership geometry.
    output_nextn_membership_report audit_output_nextn_membership(
            const server_execution::legacy_target_manifest & manifest) const;
};

}  // namespace server_inference
