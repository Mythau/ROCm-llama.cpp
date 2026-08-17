#pragma once

// Typed executor facade for Phase 2 preparation overloads. The interface
// is mechanical — it never selects a stream, block, or command category.
// The legacy planner remains the sole runtime scheduling authority.
// Defined inline in server-context.cpp where slot/batch internals are visible.

#include "server-execution-outcome.h"
#include "server-legacy-intent.h"

#include <vector>

struct server_slot;
struct server_batch;
struct common_params;

namespace server_execution {

struct legacy_authority_token {
    bool legacy_planner = true;
};

class executor {
public:
    executor() = default;

    // Step 3: Moved context-shift pass (maintenance/context shift).
    // Verbatim code moved from former pre_decode().
    void prepare_maintenance(
            const legacy_authority_token & token,
            std::vector<server_slot> & slots,
            const common_params & params_base,
            bool mctx_loaded,
            bool add_bos_token);

    // Step 3: Moved common_speculative_draft / checkpoint sequence.
    // Verbatim code moved from former pre_decode().
    legacy_intent prepare_drafts(
            const legacy_authority_token & token,
            server_batch & batch,
            std::vector<server_slot> & slots);

    // Step 4: Mechanical prompt reconciliation stage.
    // Returns one iteration-tagged outcome per named member.
    std::vector<prompt_reconciliation_outcome> prepare_prompt_reconciliation(
            const legacy_authority_token & token,
            std::vector<server_slot> & slots,
            server_batch & batch,
            const common_params & params_base);

    // aLoRA / embedding pre-decode block (3439-3458).
    void prepare_target_context(
            const legacy_authority_token & token,
            server_batch & batch);
};

}  // namespace server_execution
