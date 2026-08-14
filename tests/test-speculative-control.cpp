#include "ggml.h"
#include "speculative.h"

#ifdef NDEBUG
#undef NDEBUG
#endif

#include <cassert>

static uint32_t type_mask(common_speculative_type type) {
    return 1u << type;
}

static common_speculative_ptr make_ngram_mod_spec(
        common_ngram_mod_pool_update pool_update = COMMON_NGRAM_MOD_POOL_UPDATE_LOADED) {
    common_params_speculative params;
    params.types = { COMMON_SPECULATIVE_TYPE_NGRAM_MOD };
    params.ngram_mod.n_match = 16;
    params.ngram_mod.n_min   = 1;
    params.ngram_mod.n_max   = 1;
    params.ngram_mod.pool_update = pool_update;

    return common_speculative_ptr(common_speculative_init(params, 1));
}

static llama_tokens sequential_tokens(llama_token first, size_t count) {
    llama_tokens result;
    result.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        result.push_back(first + (llama_token) i);
    }
    return result;
}

static void set_draft_params(
        common_speculative * spec,
        const llama_tokens & prompt,
        llama_token id_last,
        llama_tokens & result) {
    auto & draft = common_speculative_get_draft_params(spec, 0);
    draft.drafting = true;
    draft.n_max    = 1;
    draft.n_past   = prompt.size();
    draft.id_last  = id_last;
    draft.prompt   = &prompt;
    draft.result   = &result;
}

static void test_ngram_mod_continues_observing_while_disabled() {
    auto spec = make_ngram_mod_spec();
    const uint32_t ngram_mod = type_mask(COMMON_SPECULATIVE_TYPE_NGRAM_MOD);

    const llama_tokens initial_prompt = sequential_tokens(100, 16);
    common_speculative_begin(spec.get(), 0, initial_prompt);
    common_speculative_disable_mask(spec.get(), 0, ngram_mod);

    // This history is long enough to cross ngram-mod's chunked observation
    // threshold. It must train the shared table without producing a draft.
    const llama_tokens observed_history = sequential_tokens(200, 49);
    llama_tokens result;
    set_draft_params(spec.get(), observed_history, 999, result);
    common_speculative_draft(spec.get());
    assert(result.empty());

    // Admission reset is the public operation which can restore eligibility.
    // Model a later eligible request and query a continuation that only
    // existed in the history observed while ngram-mod was disabled.
    common_speculative_reset_sequence(spec.get(), 0);
    llama_tokens lookup_prompt = { 999 };
    lookup_prompt.insert(lookup_prompt.end(), observed_history.begin() + 10, observed_history.begin() + 25);
    common_speculative_begin(spec.get(), 0, lookup_prompt);

    set_draft_params(spec.get(), lookup_prompt, observed_history[25], result);
    common_speculative_draft(spec.get());
    assert(result == llama_tokens({ observed_history[26] }));
    common_speculative_accept(spec.get(), 0, 1);
}

static void test_ngram_mod_observes_initial_prompt_while_disabled() {
    auto spec = make_ngram_mod_spec();
    const uint32_t ngram_mod = type_mask(COMMON_SPECULATIVE_TYPE_NGRAM_MOD);

    common_speculative_disable_mask(spec.get(), 0, ngram_mod);
    const llama_tokens observed_prompt = sequential_tokens(300, 17);
    common_speculative_begin(spec.get(), 0, observed_prompt);

    llama_tokens lookup_prompt = { 999 };
    lookup_prompt.insert(lookup_prompt.end(), observed_prompt.begin(), observed_prompt.begin() + 15);

    llama_tokens result;
    set_draft_params(spec.get(), lookup_prompt, observed_prompt[15], result);
    common_speculative_draft(spec.get());
    assert(result.empty());

    common_speculative_reset_sequence(spec.get(), 0);
    common_speculative_begin(spec.get(), 0, lookup_prompt);
    set_draft_params(spec.get(), lookup_prompt, observed_prompt[15], result);
    common_speculative_draft(spec.get());
    assert(result == llama_tokens({ observed_prompt[16] }));
    common_speculative_accept(spec.get(), 0, 1);
}

static void test_ngram_mod_eligible_mode_skips_disabled_history() {
    auto spec = make_ngram_mod_spec(COMMON_NGRAM_MOD_POOL_UPDATE_ELIGIBLE);
    const uint32_t ngram_mod = type_mask(COMMON_SPECULATIVE_TYPE_NGRAM_MOD);

    const llama_tokens initial_prompt = sequential_tokens(400, 16);
    common_speculative_begin(spec.get(), 0, initial_prompt);
    common_speculative_disable_mask(spec.get(), 0, ngram_mod);

    const llama_tokens ignored_history = sequential_tokens(500, 49);
    llama_tokens result;
    set_draft_params(spec.get(), ignored_history, 999, result);
    common_speculative_draft(spec.get());
    assert(result.empty());

    common_speculative_reset_sequence(spec.get(), 0);
    llama_tokens lookup_prompt = { 999 };
    lookup_prompt.insert(lookup_prompt.end(), ignored_history.begin() + 10, ignored_history.begin() + 25);
    common_speculative_begin(spec.get(), 0, lookup_prompt);
    set_draft_params(spec.get(), lookup_prompt, ignored_history[25], result);
    common_speculative_draft(spec.get());
    assert(result.empty());
}

static void test_ngram_mod_eligible_mode_skips_disabled_prompt() {
    auto spec = make_ngram_mod_spec(COMMON_NGRAM_MOD_POOL_UPDATE_ELIGIBLE);
    const uint32_t ngram_mod = type_mask(COMMON_SPECULATIVE_TYPE_NGRAM_MOD);

    common_speculative_disable_mask(spec.get(), 0, ngram_mod);
    const llama_tokens ignored_prompt = sequential_tokens(600, 17);
    common_speculative_begin(spec.get(), 0, ignored_prompt);

    common_speculative_reset_sequence(spec.get(), 0);
    llama_tokens lookup_prompt = { 999 };
    lookup_prompt.insert(lookup_prompt.end(), ignored_prompt.begin(), ignored_prompt.begin() + 15);
    common_speculative_begin(spec.get(), 0, lookup_prompt);

    llama_tokens result;
    set_draft_params(spec.get(), lookup_prompt, ignored_prompt[15], result);
    common_speculative_draft(spec.get());
    assert(result.empty());
}

static void test_disabled_ngram_map_does_not_begin() {
    common_params_speculative params;
    params.types = { COMMON_SPECULATIVE_TYPE_NGRAM_MAP_K };
    params.ngram_map_k.size_n = 2;
    params.ngram_map_k.size_m = 3;

    common_speculative_ptr spec(common_speculative_init(params, 1));
    const uint32_t map_k = type_mask(COMMON_SPECULATIVE_TYPE_NGRAM_MAP_K);
    common_speculative_disable_mask(spec.get(), 0, map_k);

    const llama_tokens disabled_prompt = { 1, 2, 3, 1, 2, 3, 1, 2, 3, 1 };
    common_speculative_begin(spec.get(), 0, disabled_prompt);
    common_speculative_reset_sequence(spec.get(), 0);

    // If the disabled begin reached ngram-map, its prompt cursor would be 10
    // and drafting this shorter request would reject the backwards cursor.
    const llama_tokens lookup_prompt = { 1, 2, 3, 1, 2, 3, 1 };
    llama_tokens result;
    set_draft_params(spec.get(), lookup_prompt, 2, result);
    common_speculative_draft(spec.get());
}

static void test_speculative_control() {
    ggml_time_init();

    common_params_speculative params;
    params.types = {
        COMMON_SPECULATIVE_TYPE_NGRAM_SIMPLE,
        COMMON_SPECULATIVE_TYPE_NGRAM_MAP_K,
    };
    params.ngram_simple.size_n = 2;
    params.ngram_simple.size_m = 3;
    params.ngram_map_k.size_n = 2;
    params.ngram_map_k.size_m = 3;

    common_speculative_ptr spec(common_speculative_init(params, 2));

    const uint32_t simple = type_mask(COMMON_SPECULATIVE_TYPE_NGRAM_SIMPLE);
    const uint32_t map_k  = type_mask(COMMON_SPECULATIVE_TYPE_NGRAM_MAP_K);

    assert(common_speculative_loaded_mask(spec.get()) == (simple | map_k));
    assert(common_speculative_eligible_mask(spec.get(), 0) == (simple | map_k));
    assert(common_speculative_eligible_mask(spec.get(), 1) == (simple | map_k));

    const llama_tokens prompt   = { 1, 2, 3, 1, 2, 3, 1, 2, 3, 1 };
    const llama_tokens expected_simple = { 3, 1 };
    const llama_tokens expected_map_k  = { 3, 1, 2 };
    llama_tokens result;

    common_speculative_begin(spec.get(), 0, prompt);

    auto & draft = common_speculative_get_draft_params(spec.get(), 0);
    draft.drafting = true;
    draft.n_max    = 3;
    draft.n_past   = prompt.size();
    draft.id_last  = 2;
    draft.prompt   = &prompt;
    draft.result   = &result;

    common_speculative_draft(spec.get());
    assert(result == expected_simple);
    common_speculative_accept(spec.get(), 0, 0);

    common_speculative_disable_mask(spec.get(), 0, simple);
    assert(common_speculative_eligible_mask(spec.get(), 0) == map_k);
    assert(common_speculative_eligible_mask(spec.get(), 1) == (simple | map_k));

    result.clear();
    draft.drafting = true;
    common_speculative_draft(spec.get());
    assert(result == expected_map_k);
    common_speculative_accept(spec.get(), 0, 0);

    common_speculative_disable_mask(spec.get(), 0, map_k);
    result.clear();
    draft.drafting = true;
    common_speculative_draft(spec.get());
    assert(result.empty());

    common_speculative_reset_sequence(spec.get(), 0);
    assert(common_speculative_eligible_mask(spec.get(), 0) == (simple | map_k));
    assert(common_speculative_eligible_mask(spec.get(), 1) == (simple | map_k));
}

int main() {
    test_speculative_control();
    test_ngram_mod_continues_observing_while_disabled();
    test_ngram_mod_observes_initial_prompt_while_disabled();
    test_ngram_mod_eligible_mode_skips_disabled_history();
    test_ngram_mod_eligible_mode_skips_disabled_prompt();
    test_disabled_ngram_map_does_not_begin();
    return 0;
}
