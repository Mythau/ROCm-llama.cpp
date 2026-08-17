#pragma once

// Temporary phase-2 legacy scheduling capture. No authority transfer:
// the legacy planner remains the sole runtime scheduling authority.
// Deleted atomically in Phase 3 (COHORT_BATCHING_PHASED_IMPLEMENTATION_PLAN.md:599-602).

#include "inference-identity.h"

#include <cstdint>
#include <vector>

namespace server_execution {

struct legacy_intent {
    inference::identity::iteration_id iteration;
    // Slot ids that were selected for generating/drafting by the
    // unchanged legacy planner — mirrored directly from the slot
    // vectors produced by the generating/draft scan.
    std::vector<int32_t> generating_ids;
    std::vector<int32_t> drafting_ids;
};

struct legacy_target_manifest {
    inference::identity::iteration_id iteration;
};

// Forward declare the temporary seam functions — definitions live
// in server-context.cpp as private members of server_context_impl.

}  // namespace server_execution
