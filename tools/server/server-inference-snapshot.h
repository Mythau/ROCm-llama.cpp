#pragma once

#include "inference-identity.h"
#include "inference-profile.h"

#include <cstdint>
#include <optional>

namespace server_inference {

enum class lifecycle {
    WAIT_OTHER,
    STARTED,
    PROMPT,
    DONE_PROMPT_BEFORE_SAMPLE,
    GENERATING,
};

enum class task_kind {
    COMPLETION,
    INFILL,
    EMBEDDING,
    RERANK,
    MODEL_MUTATION,
};

enum class input_kind {
    TOKEN_SEQUENCE,
    EMBEDDING,
    RERANK,
    MULTIMODAL,
};

struct dependency_fact {
    std::optional<int64_t> parent_task_id;
    bool                   satisfied;
};

struct speculative_capabilities {
    uint32_t loaded_mask;
    uint32_t runtime_eligible_mask;
    uint32_t non_mtp_available_mask;
    uint32_t non_mtp_required_mask;
    bool     runtime_synchronized;
    bool     mtp_context_available;
    bool     cache_mtp_compatible;
    bool     can_prefill_mtp_from_scratch;
    bool     context_shift_may_demote_mtp;
    int32_t  mtp_max_draft_rows;
    int32_t  ngram_max_draft_rows;
    int32_t  other_max_draft_rows;
};

struct stream_snapshot {
    inference::identity::stream_key       stream;
    bool                                  attached;
    bool                                  live;
    lifecycle                             state;
    task_kind                             kind;
    input_kind                            input;
    int32_t                               embedding_width;
    dependency_fact                       dependency;
    inference::profile::adapter_signature adapters;
    bool                                  alora_active;
    speculative_capabilities              speculation;

    uint64_t raw_prompt_tokens_total;
    bool     raw_fresh_verification_candidate;
    int32_t  raw_mandatory_replay_rows;
    int64_t  raw_target_physical_position;
    int64_t  raw_draft_physical_position;
    int32_t  raw_prepared_speculative_extent;

    uint64_t output_committed_count;
    bool     pending_sampled_input;
};

struct raw_stream_state {
    stream_snapshot passive;
    uint64_t        raw_n_decoded;
    bool            raw_sampled_input;
};

stream_snapshot project_current_task(const raw_stream_state & raw);

}  // namespace server_inference
