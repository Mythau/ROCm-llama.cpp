#include "server-execution.h"

// Stub TU: every executor overload returns a default/empty value. The real
// work is NOT defined here — it lives in server_context_impl members in
// server-context.cpp (make_legacy_intent, pre_decode, update_slots).
// This file compiles only into the dormant test target
// (tests/CMakeLists.txt), not into the production server-context library.
// Out-of-line definitions may be moved here in Phase 3 when slot types are
// header-visible.

namespace server_execution {

// These stubs satisfy the linker for the dormant test target; they are
// never called at runtime because the production server-context library
// does not include this TU.

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

target_batch_outcome executor::execute_target_manifest(
        const legacy_authority_token &,
        const legacy_target_manifest &,
        llama_context *,
        server_batch &,
        std::vector<server_slot> &) {
    return target_batch_outcome{};
}

int executor::external_execute_mtmd(
        const legacy_scoped_mtmd_authorization &,
        std::vector<server_slot> &,
        server_batch &) {
    return -1;
}

}  // namespace server_execution
