#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

struct server_speculative_policy_stream {
    int32_t  seq_id;
    uint32_t eligible_mask;
};

struct server_speculative_policy_limit {
    uint32_t type_mask;
    size_t   max_active_streams;
};

struct server_speculative_policy_removal {
    int32_t  seq_id;
    uint32_t mask;
};

struct server_speculative_policy_plan {
    std::vector<uint32_t>                          incoming_masks;
    std::vector<server_speculative_policy_removal> removals;
};

// Pure occupancy policy. Existing streams are never granted eligibility; callers
// apply the returned removals at the admission transaction's safe point.
server_speculative_policy_plan server_speculative_plan_occupancy(
    const std::vector<server_speculative_policy_stream> & active_streams,
    size_t                                                incoming_stream_count,
    uint32_t                                              loaded_mask,
    const std::vector<server_speculative_policy_limit> &  limits);
