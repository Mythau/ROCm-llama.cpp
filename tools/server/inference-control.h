#pragma once

#include "inference-identity.h"
#include "inference-profile.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace inference::control {

enum class phase { NORMAL, COHORT_ENTRY_DRAIN, COHORT_INTERMISSION, COHORT_FORM, COHORT_PREFILL, COHORT_DECODE };

struct config {
    int32_t entry_streams;
    int32_t exit_streams;
};

struct active_cohort {
    identity::cohort_id                 id;
    profile::adapter_signature          adapters;
    profile::cohort_speculative_profile speculation;
    std::vector<identity::stream_key>   members;
    size_t                              prompt_cursor;
};

}  // namespace inference::control
