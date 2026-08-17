#include "server-progress-comparator.h"

#include <algorithm>
#include <string>
#include <unordered_set>
#include <cstdint>

namespace server_inference {

#ifdef LLAMA_COHORT_DIAGNOSTICS

projected_pending_work project_pending_work(
        const std::vector<stream_snapshot> & post_reconciliation) {
    projected_pending_work projection;
    for (const stream_snapshot & snap : post_reconciliation) {
        switch (snap.state) {
        case lifecycle::PROMPT:
            projection.items.push_back({
                pending_work_item::category::PROMPT, snap.stream, 0,
            });
            break;
        case lifecycle::DONE_PROMPT_BEFORE_SAMPLE:
            projection.items.push_back({
                pending_work_item::category::SAMPLED_INPUT, snap.stream, 0,
            });
            break;
        case lifecycle::GENERATING:
            if (snap.pending_sampled_input) {
                projection.items.push_back({
                    pending_work_item::category::SAMPLED_INPUT, snap.stream, 0,
                });
            }
            if (snap.raw_prepared_speculative_extent > 0) {
                projection.items.push_back({
                    pending_work_item::category::DRAFT, snap.stream, snap.raw_prepared_speculative_extent,
                });
            }
            if (snap.raw_mandatory_replay_rows > 0) {
                projection.items.push_back({
                    pending_work_item::category::REPLAY, snap.stream, snap.raw_mandatory_replay_rows,
                });
            }
            break;
        default:
            break;
        }
    }
    return projection;
}

progress_comparison_report progress_comparator::compare(
        const std::vector<stream_snapshot> & post_reconciliation,
        const server_execution::legacy_target_manifest & manifest,
        const std::optional<server_execution::target_batch_outcome> & complete_outcome) const {
    progress_comparison_report report;
    report.published = complete_outcome.has_value() &&
                       complete_outcome->iteration == manifest.iteration;
    if (!report.published) {
        // Iteration incomplete (preparation in flight, between batch_view
        // values, or a non-target completion): publish nothing.
        return report;
    }

    report.pending = project_pending_work(post_reconciliation);
    report.pending.iteration = manifest.iteration;

    for (std::size_t r = 0; r < manifest.rows.size(); r++) {
        const server_execution::target_manifest_row & row = manifest.rows[r];
        manifest_row_provenance provenance;
        provenance.row_index         = r;
        provenance.provenance        = manifest_row_provenance::source::UNEXPLAINED;
        provenance.pending_item_index = 0;
        for (std::size_t p = 0; p < report.pending.items.size(); p++) {
            if (report.pending.items[p].stream.slot_id == row.slot_id) {
                provenance.provenance         = manifest_row_provenance::source::PENDING_WORK;
                provenance.pending_item_index = p;
                break;
            }
        }
        report.row_coverage.push_back(provenance);
    }

    for (std::size_t r = 0; r < complete_outcome->results.size(); r++) {
        const server_execution::target_execution_result & result = complete_outcome->results[r];
        bool member = false;
        for (const server_execution::target_manifest_row & row : manifest.rows) {
            if (row.slot_id == result.stream.slot_id) {
                member = true;
                break;
            }
        }
        report.outcome_coverage.push_back({ r, member });
    }
    return report;
}

prepared_live_invariant_report progress_comparator::audit_prepared_live(
        const std::vector<server_execution::prepared_decode_outcome> & prepared,
        const server_execution::legacy_intent & intent,
        const server_execution::legacy_target_manifest & manifest) const {
    prepared_live_invariant_report report;

    std::unordered_set<int32_t> manifest_slots;
    for (const server_execution::target_manifest_row & row : manifest.rows) {
        manifest_slots.insert(row.slot_id);
    }

    std::unordered_set<int32_t> intent_draft_set(intent.drafting_ids.begin(),
                                                  intent.drafting_ids.end());

    for (const server_execution::prepared_decode_outcome & outcome : prepared) {
        if (manifest_slots.find(outcome.owner.slot_id) == manifest_slots.end()) {
            report.all_prepared_in_manifest = false;
            report.findings.push_back(
                "prepared slot " + std::to_string(outcome.owner.slot_id) +
                " absent from finalized manifest");
        }
    }

    for (const server_execution::target_manifest_row & row : manifest.rows) {
        if (!row.is_nextn) {
            continue;
        }
        bool found = false;
        for (const server_execution::prepared_decode_outcome & outcome : prepared) {
            if (outcome.owner.slot_id == row.slot_id) {
                found = true;
                break;
            }
        }
        if (!found) {
            report.no_manifest_omission = false;
            report.findings.push_back(
                "NextN block for slot " + std::to_string(row.slot_id) +
                " has no prepared_decode_outcome");
        }
        if (intent_draft_set.find(row.slot_id) == intent_draft_set.end()) {
            report.bulk_draft_only_intent = false;
            report.findings.push_back(
                "NextN block for undrafted slot " + std::to_string(row.slot_id));
        }
    }

    return report;
}

output_nextn_membership_report progress_comparator::audit_output_nextn_membership(
        const server_execution::legacy_target_manifest & manifest) const {
    output_nextn_membership_report report;

    for (std::size_t i = 0; i < manifest.rows.size(); i++) {
        const server_execution::target_manifest_row & row = manifest.rows[i];
        if (row.logical_rows < 1) {
            report.all_rows_explained = false;
            report.findings.push_back(
                "row " + std::to_string(i) + " has logical_rows < 1");
        }
        if (!row.has_output && !row.is_nextn && !row.is_replay) {
            report.all_rows_explained = false;
            report.findings.push_back(
                "row " + std::to_string(i) + " slot " +
                std::to_string(row.slot_id) +
                " has no output/nextn/replay flag");
        }
    }

    return report;
}

#else

projected_pending_work project_pending_work(
        const std::vector<stream_snapshot> & post_reconciliation) {
    return {};
}

progress_comparison_report progress_comparator::compare(
        const std::vector<stream_snapshot> &,
        const server_execution::legacy_target_manifest &,
        const std::optional<server_execution::target_batch_outcome> &) const {
    // Diagnostics compiled out: never publish a projection.
    return {};
}

prepared_live_invariant_report progress_comparator::audit_prepared_live(
        const std::vector<server_execution::prepared_decode_outcome> &,
        const server_execution::legacy_intent &,
        const server_execution::legacy_target_manifest &) const {
    return {};
}

output_nextn_membership_report progress_comparator::audit_output_nextn_membership(
        const server_execution::legacy_target_manifest &) const {
    return {};
}

#endif

}  // namespace server_inference
