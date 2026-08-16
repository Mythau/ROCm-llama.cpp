#pragma once

#include "inference-profile.h"
#include "server-inference-snapshot.h"

#include <vector>

namespace inference::admission {

enum class formation_incompatibility {
    NONE,
    MIXED_ADAPTER_SIGNATURES,
    NO_HOMOGENEOUS_SPECULATIVE_PROFILE,
};

struct formation_assessment {
    std::vector<identity::stream_key>   exact_scope;
    bool                                compatible;
    profile::adapter_signature          adapters;
    profile::cohort_speculative_profile speculation;
    formation_incompatibility           reason;
};

formation_assessment assess_formation(const std::vector<server_inference::stream_snapshot> & exact_scope);

}  // namespace inference::admission
