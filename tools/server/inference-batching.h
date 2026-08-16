#pragma once

#include "inference-identity.h"
#include "server-inference-snapshot.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace inference::batching {

struct normal_compatibility_candidate {
    identity::stream_key         owner;
    server_inference::task_kind  task;
    server_inference::input_kind input;
    int32_t                      embedding_width;
    bool                         effective_alora;
    profile::adapter_signature   adapters;
};

struct normal_compatibility_proposal {
    std::vector<identity::stream_key> members;
};

normal_compatibility_proposal propose_normal_compatibility_group(
    const std::vector<normal_compatibility_candidate> & ordered_candidates);

struct decode_row_reservation {
    identity::stream_key owner;
    int32_t              logical_rows;
    int32_t              effective_ngram_max;
    bool                 sampled_only_fallback;
    bool                 replay;
};

struct decode_candidate {
    identity::stream_key                               owner;
    bool                                               fresh_candidate;
    int32_t                                            mandatory_replay_rows;
    int32_t                                            mtp_max_draft_rows;
    int32_t                                            ngram_max_draft_rows;
    int32_t                                            ngram_min_draft_rows;
    int32_t                                            other_max_draft_rows;
    std::optional<profile::cohort_speculative_profile> frozen_profile;
    uint32_t                                           effective_eligible_mask;
    uint32_t                                           mtp_implementation_mask;
    uint32_t                                           ngram_implementation_mask;
    uint32_t                                           other_implementation_mask;
};

struct decode_reservation_proposal {
    std::vector<decode_row_reservation> reservations;
    bool                                feasible;
    int32_t                             reserved_rows;
};

decode_reservation_proposal propose_decode_reservations(const std::vector<decode_candidate> & candidates,
                                                        int32_t                               logical_n_batch,
                                                        bool require_all_participants);

struct prompt_candidate {
    identity::stream_key owner;
    int32_t              available_rows;
};

struct prompt_grant {
    identity::stream_key owner;
    int32_t              rows;
};

struct prompt_grant_proposal {
    std::vector<prompt_grant> prompt_grants;
    size_t                    proposed_next_cursor;
};

prompt_grant_proposal propose_contiguous_prompt_grants(const std::vector<identity::stream_key> & member_order,
                                                       const std::vector<prompt_candidate> &     candidates,
                                                       size_t                                    prompt_cursor,
                                                       int32_t                                   logical_capacity);

}  // namespace inference::batching
