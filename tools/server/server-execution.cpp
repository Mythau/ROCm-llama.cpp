#include "server-execution.h"

// Stub: the real executor overloads are defined in server-context.cpp
// where slot/batch internals are visible. This file compiles into the
// server-context library and serves as the placeholder for the out-of-line
// definitions when slot types are header-visible in Phase 3.

namespace server_execution {

// The real implementations live in server_context_impl member functions
// (server-context.cpp). These stubs satisfy the linker; they are never
// called because update_slots() calls the direct member functions.

void executor::prepare_maintenance(
        const legacy_authority_token &,
        std::vector<server_slot> &,
        const common_params &,
        bool, bool) {}

legacy_intent executor::prepare_drafts(
        const legacy_authority_token &,
        server_batch &,
        std::vector<server_slot> &) {
    return legacy_intent{};
}

std::vector<prompt_reconciliation_outcome> executor::prepare_prompt_reconciliation(
        const legacy_authority_token &,
        std::vector<server_slot> &,
        server_batch &,
        const common_params &) {
    return {};
}

void executor::prepare_target_context(
        const legacy_authority_token &,
        server_batch &) {}

}  // namespace server_execution
