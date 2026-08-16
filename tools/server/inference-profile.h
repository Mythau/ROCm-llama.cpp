#pragma once

#include <cstdint>
#include <vector>

namespace inference::profile {

struct adapter_binding {
    uint64_t adapter_id;
    float    scale;
};

inline bool operator==(const adapter_binding & lhs, const adapter_binding & rhs) {
    return lhs.adapter_id == rhs.adapter_id && lhs.scale == rhs.scale;
}

struct adapter_signature {
    std::vector<adapter_binding> ordered;
};

inline bool operator==(const adapter_signature & lhs, const adapter_signature & rhs) {
    return lhs.ordered == rhs.ordered;
}

inline bool operator!=(const adapter_signature & lhs, const adapter_signature & rhs) {
    return !(lhs == rhs);
}

enum class cohort_mtp_mode {
    OFF,
    IMMEDIATE,
};

struct cohort_speculative_profile {
    cohort_mtp_mode mtp;
    uint32_t        non_mtp_eligible_mask;
};

inline bool operator==(const cohort_speculative_profile & lhs, const cohort_speculative_profile & rhs) {
    return lhs.mtp == rhs.mtp && lhs.non_mtp_eligible_mask == rhs.non_mtp_eligible_mask;
}

}  // namespace inference::profile
