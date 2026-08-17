#pragma once

// Typed executor facade for Phase 2 preparation overloads. The interface
// is a Phase 2 placeholder. The legacy planner remains the sole runtime
// scheduling authority. All overloads are currently stub (declaration-only;
// the real work lives in server_context_impl members in server-context.cpp).
// Body extraction from server-context.cpp is deferred to Phase 3. The
// stub TU server-execution.cpp is compiled into the dormant test target
// only, not linked into production llama-server.

#include "server-execution-outcome.h"
#include "server-legacy-intent.h"

#include <vector>

struct server_slot;
struct server_batch;
struct common_params;
struct llama_context;

namespace server_execution {

struct legacy_authority_token {
    bool legacy_planner = true;
};

// Step 8: exact-task-scoped multimodal authorization.
// Temporary legacy-issued; the executor is structurally unable to
// select a multimodal task or discover media chunks on its own.
struct exact_task_scope {
    inference::identity::stream_key stream;
};

struct legacy_scoped_mtmd_authorization {
    bool legacy_planner = true;
    exact_task_scope scope;
};

struct verification_prefix_unfit {
    inference::identity::iteration_id iteration;
};

class executor {
public:
    executor() = default;

    // Step 3 placeholder: context-shift pass (maintenance/context shift).
    // Stub; real body is server_context_impl::make_legacy_intent() in
    // server-context.cpp.
    void prepare_maintenance(
            const legacy_authority_token & token,
            std::vector<server_slot> & slots,
            const common_params & params_base,
            bool mctx_loaded,
            bool add_bos_token);

    // Step 3 placeholder: common_speculative_draft / checkpoint sequence.
    // Stub; real body is server_context_impl::make_legacy_intent() in
    // server-context.cpp.
    legacy_intent prepare_drafts(
            const legacy_authority_token & token,
            server_batch & batch,
            std::vector<server_slot> & slots);

    // Step 4 placeholder: mechanical prompt reconciliation stage.
    // Stub returning {}; real inline recording lives in
    // server_context_impl::pre_decode() in server-context.cpp.
    std::vector<prompt_reconciliation_outcome> prepare_prompt_reconciliation(
            const legacy_authority_token & token,
            std::vector<server_slot> & slots,
            server_batch & batch,
            const common_params & params_base);

    // aLoRA / embedding pre-decode block placeholder (former 3439-3458).
    // Stub; real body remains in server-context.cpp.
    void prepare_target_context(
            const legacy_authority_token & token,
            server_batch & batch);

    // Step 8 placeholder: target execution (builds exact server_batch,
    // decode/view loop, batch_view accumulation). Stub returning {}; the
    // real decode/view loop remains in update_slots() in server-context.cpp.
    target_batch_outcome execute_target_manifest(
            const legacy_authority_token & token,
            const legacy_target_manifest & manifest,
            llama_context * ctx_tgt,
            server_batch & batch,
            std::vector<server_slot> & slots);

    // Step 8 placeholder: exact-task-scoped multimodal execution.
    // Stub returning -1 unconditionally; the real multimodal loop remains
    // inline in pre_decode() in server-context.cpp.
    int external_execute_mtmd(
            const legacy_scoped_mtmd_authorization & auth,
            std::vector<server_slot> & slots,
            server_batch & batch);
};

}  // namespace server_execution
