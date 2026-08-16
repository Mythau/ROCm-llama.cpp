#include "inference-batching.h"

#include <algorithm>

namespace inference::batching {

normal_compatibility_proposal propose_normal_compatibility_group(
    const std::vector<normal_compatibility_candidate> & ordered_candidates) {
    normal_compatibility_proposal result;
    if (ordered_candidates.empty()) {
        return result;
    }

    const auto & first = ordered_candidates.front();
    for (const auto & candidate : ordered_candidates) {
        if (candidate.task == first.task && candidate.input == first.input &&
            candidate.embedding_width == first.embedding_width && candidate.effective_alora == first.effective_alora &&
            candidate.adapters == first.adapters) {
            result.members.push_back(candidate.owner);
        }
    }
    return result;
}

static uint32_t allowed_implementations(const decode_candidate & candidate) {
    uint32_t allowed_mask = candidate.effective_eligible_mask;
    if (candidate.frozen_profile.has_value()) {
        allowed_mask &= candidate.frozen_profile->non_mtp_eligible_mask |
                        (candidate.frozen_profile->mtp == profile::cohort_mtp_mode::IMMEDIATE ?
                             candidate.mtp_implementation_mask :
                             0);
    }
    return allowed_mask;
}

static int32_t max_draft_rows(const decode_candidate & candidate, int32_t effective_ngram_max) {
    const uint32_t allowed_mask = allowed_implementations(candidate);
    const bool mtp_allowed   = (allowed_mask & candidate.mtp_implementation_mask) != 0;
    const bool ngram_allowed = (allowed_mask & candidate.ngram_implementation_mask) != 0;
    const bool other_allowed = (allowed_mask & candidate.other_implementation_mask) != 0;
    return std::max({ mtp_allowed ? candidate.mtp_max_draft_rows : 0,
                      ngram_allowed ? effective_ngram_max : 0,
                      other_allowed ? candidate.other_max_draft_rows : 0 });
}

decode_reservation_proposal propose_decode_reservations(const std::vector<decode_candidate> & candidates,
                                                        int32_t                               logical_n_batch,
                                                        bool require_all_participants) {
    decode_reservation_proposal result{ {}, true, 0 };

    std::vector<const decode_candidate *> fresh;
    for (const auto & candidate : candidates) {
        if (candidate.mandatory_replay_rows > 0) {
            if (result.reserved_rows + candidate.mandatory_replay_rows > logical_n_batch) {
                result.feasible = false;
                result.reservations.clear();
                result.reserved_rows = 0;
                return result;
            }
            result.reservations.push_back({ candidate.owner, candidate.mandatory_replay_rows, 0, false, true });
            result.reserved_rows += candidate.mandatory_replay_rows;
        } else if (candidate.fresh_candidate) {
            fresh.push_back(&candidate);
        }
    }

    if (fresh.empty()) {
        return result;
    }

    const int32_t        residual = logical_n_batch - result.reserved_rows;
    std::vector<int32_t> allowances(fresh.size());
    if (require_all_participants) {
        std::vector<int32_t> envelopes(fresh.size());
        int32_t              floor_rows = 0;
        for (size_t i = 0; i < fresh.size(); ++i) {
            const auto & candidate    = *fresh[i];
            const auto   allowed_mask = allowed_implementations(candidate);
            const int32_t floor = 1 + std::max({ (allowed_mask & candidate.mtp_implementation_mask) != 0 ?
                                                     candidate.mtp_max_draft_rows :
                                                     0,
                                                 (allowed_mask & candidate.other_implementation_mask) != 0 ?
                                                     candidate.other_max_draft_rows :
                                                     0,
                                                 0 });
            const bool ngram_allowed = (allowed_mask & candidate.ngram_implementation_mask) != 0;
            allowances[i]            = floor;
            envelopes[i]             = ngram_allowed ? std::max(floor, 1 + candidate.ngram_max_draft_rows) : floor;
            floor_rows += floor;
        }
        if (floor_rows > residual) {
            result.feasible = false;
            result.reservations.clear();
            result.reserved_rows = 0;
            return result;
        }

        int32_t marginal_rows = residual - floor_rows;
        while (marginal_rows > 0) {
            size_t next = allowances.size();
            for (size_t i = 0; i < allowances.size(); ++i) {
                if (allowances[i] < envelopes[i] &&
                    (next == allowances.size() || allowances[i] < allowances[next])) {
                    next = i;
                }
            }
            if (next == allowances.size()) {
                break;
            }
            ++allowances[next];
            --marginal_rows;
        }
    }

    for (size_t i = 0; i < fresh.size(); ++i) {
        const auto &  candidate    = *fresh[i];
        const int32_t allowance    = require_all_participants ?
                                         allowances[i] :
                                         logical_n_batch - result.reserved_rows;
        const auto allowed_mask = allowed_implementations(candidate);
        const bool ngram_allowed = (allowed_mask & candidate.ngram_implementation_mask) != 0;
        int32_t ngram_cap = ngram_allowed ?
            std::min(candidate.ngram_max_draft_rows, std::max(0, allowance - 1)) :
            0;
        const bool sampled_only_fallback = ngram_allowed && candidate.ngram_max_draft_rows > 0 &&
                                           ngram_cap < candidate.ngram_min_draft_rows;
        if (sampled_only_fallback) {
            ngram_cap = 0;
        }

        const int32_t rows = sampled_only_fallback ? 1 : 1 + max_draft_rows(candidate, ngram_cap);
        if (rows > allowance || result.reserved_rows + rows > logical_n_batch) {
            if (require_all_participants) {
                result.feasible = false;
                result.reservations.clear();
                result.reserved_rows = 0;
                return result;
            }
            continue;
        }

        result.reservations.push_back({ candidate.owner, rows, ngram_cap, sampled_only_fallback, false });
        result.reserved_rows += rows;
    }

    return result;
}

static int32_t available_for(identity::stream_key key, const std::vector<prompt_candidate> & candidates) {
    const auto it = std::find_if(candidates.begin(), candidates.end(),
                                 [key](const auto & candidate) { return candidate.owner == key; });
    return it == candidates.end() ? 0 : it->available_rows;
}

prompt_grant_proposal propose_contiguous_prompt_grants(const std::vector<identity::stream_key> & member_order,
                                                       const std::vector<prompt_candidate> &     candidates,
                                                       size_t                                    prompt_cursor,
                                                       int32_t                                   logical_capacity) {
    prompt_grant_proposal result{ {}, member_order.empty() ? 0 : prompt_cursor % member_order.size() };
    if (member_order.empty() || logical_capacity <= 0) {
        return result;
    }

    std::vector<identity::stream_key> eligible;
    for (size_t offset = 0; offset < member_order.size(); ++offset) {
        const auto key = member_order[(prompt_cursor + offset) % member_order.size()];
        if (available_for(key, candidates) > 0) {
            eligible.push_back(key);
        }
    }

    int32_t                             remaining = logical_capacity;
    std::optional<identity::stream_key> first_granted;
    for (size_t i = 0; i < eligible.size() && remaining > 0; ++i) {
        const int32_t streams_left = static_cast<int32_t>(eligible.size() - i);
        const int32_t fair_share   = (remaining + streams_left - 1) / streams_left;
        const int32_t grant        = std::min(available_for(eligible[i], candidates), fair_share);
        if (grant <= 0) {
            continue;
        }
        if (!first_granted.has_value()) {
            first_granted = eligible[i];
        }
        result.prompt_grants.push_back({ eligible[i], grant });
        remaining -= grant;
    }

    if (first_granted.has_value()) {
        const auto it = std::find(member_order.begin(), member_order.end(), *first_granted);
        result.proposed_next_cursor = (static_cast<size_t>(it - member_order.begin()) + 1) % member_order.size();
    }
    return result;
}

}  // namespace inference::batching
