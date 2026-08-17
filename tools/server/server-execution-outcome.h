#pragma once

#include "inference-identity.h"
#include <cstdint>

namespace server_execution {

struct prompt_reconciliation_result {
    inference::identity::stream_key owner;
    uint64_t                        prompt_total;
    uint64_t                        reconciled_prompt_coverage;
    int32_t                         contiguous_cap;
    bool                            last_logit_pending;
    bool                            live;
};

}  // namespace server_execution
