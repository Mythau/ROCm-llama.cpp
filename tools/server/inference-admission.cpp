#include "inference-admission.h"

namespace inference::admission {

static uint32_t allowed_non_mtp(const server_inference::stream_snapshot & snapshot) {
    return snapshot.speculation.non_mtp_available_mask & snapshot.speculation.loaded_mask &
           snapshot.speculation.runtime_eligible_mask;
}

static bool supports_immediate_mtp(const server_inference::stream_snapshot & snapshot) {
    return snapshot.speculation.mtp_context_available &&
           ((snapshot.speculation.cache_mtp_compatible && snapshot.speculation.runtime_synchronized) ||
            snapshot.speculation.can_prefill_mtp_from_scratch) &&
           !snapshot.speculation.context_shift_may_demote_mtp;
}

formation_assessment assess_formation(const std::vector<server_inference::stream_snapshot> & exact_scope) {
    formation_assessment result{
        {}, true, {},
          { profile::cohort_mtp_mode::OFF, 0 },
          formation_incompatibility::NONE,
    };

    result.exact_scope.reserve(exact_scope.size());
    for (const auto & snapshot : exact_scope) {
        result.exact_scope.push_back(snapshot.stream);
    }

    if (exact_scope.empty()) {
        return result;
    }

    result.adapters              = exact_scope.front().adapters;
    uint32_t common_non_mtp_mask = allowed_non_mtp(exact_scope.front());
    bool immediate               = exact_scope.front().adapters.ordered.empty();

    for (const auto & snapshot : exact_scope) {
        if (snapshot.adapters != result.adapters) {
            result.compatible = false;
            result.reason     = formation_incompatibility::MIXED_ADAPTER_SIGNATURES;
            return result;
        }

        common_non_mtp_mask &= allowed_non_mtp(snapshot);
        immediate = immediate && supports_immediate_mtp(snapshot);
    }

    for (const auto & snapshot : exact_scope) {
        if ((snapshot.speculation.non_mtp_required_mask & common_non_mtp_mask) !=
            snapshot.speculation.non_mtp_required_mask) {
            result.compatible = false;
            result.reason     = formation_incompatibility::NO_HOMOGENEOUS_SPECULATIVE_PROFILE;
            return result;
        }
    }

    result.speculation = {
        immediate ? profile::cohort_mtp_mode::IMMEDIATE : profile::cohort_mtp_mode::OFF,
        common_non_mtp_mask,
    };
    return result;
}

}  // namespace inference::admission
