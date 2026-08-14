#include "server-speculative-policy.h"

uint32_t server_speculative_allowed_mask(
    size_t                                               active_stream_count,
    uint32_t                                             loaded_mask,
    const std::vector<server_speculative_policy_limit> & limits) {
    uint32_t result = loaded_mask;
    for (const auto & limit : limits) {
        if (active_stream_count > limit.max_active_streams) {
            result &= ~limit.type_mask;
        }
    }
    return result;
}

server_speculative_policy_plan server_speculative_plan_occupancy(
    const std::vector<server_speculative_policy_stream> & active_streams,
    size_t                                                incoming_stream_count,
    uint32_t                                              loaded_mask,
    const std::vector<server_speculative_policy_limit> &  limits) {
    const size_t prospective_stream_count = active_streams.size() + incoming_stream_count;

    const uint32_t allowed_mask = server_speculative_allowed_mask(
            prospective_stream_count, loaded_mask, limits);
    const uint32_t removal_mask = loaded_mask & ~allowed_mask;

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
