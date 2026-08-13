#include "server-speculative-policy.h"

server_speculative_policy_plan server_speculative_plan_occupancy(
    const std::vector<server_speculative_policy_stream> & active_streams,
    size_t                                                incoming_stream_count,
    uint32_t                                              loaded_mask,
    const std::vector<server_speculative_policy_limit> &  limits) {
    const size_t prospective_stream_count = active_streams.size() + incoming_stream_count;

    uint32_t removal_mask = 0;
    for (const auto & limit : limits) {
        if (prospective_stream_count > limit.max_active_streams) {
            removal_mask |= limit.type_mask & loaded_mask;
        }
    }

    server_speculative_policy_plan result;
    result.incoming_masks.assign(incoming_stream_count, loaded_mask & ~removal_mask);
    result.removals.reserve(active_streams.size());

    for (const auto & stream : active_streams) {
        const uint32_t stream_removal_mask = stream.eligible_mask & removal_mask;
        if (stream_removal_mask != 0) {
            result.removals.push_back({ stream.seq_id, stream_removal_mask });
        }
    }

    return result;
}
