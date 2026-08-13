#include "ggml.h"
#include "speculative.h"

#ifdef NDEBUG
#undef NDEBUG
#endif

#include <cassert>

static uint32_t type_mask(common_speculative_type type) {
    return 1u << type;
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
    return 0;
}
