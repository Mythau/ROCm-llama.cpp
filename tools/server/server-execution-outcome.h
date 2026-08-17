#pragma once

#include "inference-identity.h"

#include <cstdint>
#include <variant>
#include <vector>

namespace server_execution {

struct prompt_reconciliation_outcome {
    inference::identity::iteration_id iteration;
    inference::identity::stream_key   owner;
    uint64_t                          prompt_total;
    uint64_t                          reconciled_prompt_coverage;
    int32_t                           contiguous_cap;
};

enum class decode_block_origin {
    FRESH,
    REPLAY,
};

struct prepared_decode_outcome {
    inference::identity::iteration_id iteration;
    uint64_t                          block_id;
    inference::identity::stream_key   owner;
    int32_t                           logical_rows;
    decode_block_origin               origin;
};

enum class target_execution_result_kind {
    STREAM_ADVANCED,
    REPLAY_CREATED,
    COMPLETED,
    CANCELLED,
    FAILED,
};

struct target_execution_result {
    inference::identity::stream_key stream;
    target_execution_result_kind    kind;
    uint64_t                        block_id;
    int32_t                         logical_rows;
};

struct target_batch_outcome {
    inference::identity::iteration_id   iteration;
    std::vector<target_execution_result> results;
};

struct admission_only_completion {
    inference::identity::iteration_id iteration;
};

struct zero_work_completion {
    inference::identity::iteration_id iteration;
};

struct terminal_failure_completion {
    inference::identity::iteration_id iteration;
    const char *                      reason;
};

using iteration_completion_payload = std::variant<target_batch_outcome,
                                                  admission_only_completion,
                                                  zero_work_completion,
                                                  terminal_failure_completion>;

struct iteration_completion {
    inference::identity::iteration_id iteration;
    iteration_completion_payload      payload;
};

}  // namespace server_execution
