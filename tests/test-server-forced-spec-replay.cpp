#include "../tools/server/server-spec-forced-replay.h"

#ifdef NDEBUG
#undef NDEBUG
#endif

#include <cassert>
#include <vector>

static void assert_tail_only_output(const server_spec_forced_replay & replay) {
    for (size_t i = 0; i < replay.tokens.size(); ++i) {
        assert(replay.requests_output(i) == (i + 1 == replay.tokens.size()));
    }
}

static void test_zero_accepted_draft_tokens() {
    server_spec_forced_replay replay;
    replay.begin({ 91 }, 4);

    assert(replay.active());
    assert(replay.accepted_draft_size == 0);
    assert_tail_only_output(replay);

    const auto emitted = replay.finish(92);
    assert((emitted == std::vector<llama_token> { 91, 92 }));
    assert(!replay.active());
}

static void test_partial_acceptance() {
    server_spec_forced_replay replay;
    replay.begin({ 21, 22, 99 }, 4);

    assert(replay.original_draft_size == 4);
    assert(replay.accepted_draft_size == 2);
    assert_tail_only_output(replay);

    const auto emitted = replay.finish(100);
    assert((emitted == std::vector<llama_token> { 21, 22, 99, 100 }));
    assert(!replay.active());
}

static void test_full_acceptance() {
    server_spec_forced_replay replay;
    replay.begin({ 31, 32, 33, 34 }, 3);

    assert(replay.original_draft_size == 3);
    assert(replay.accepted_draft_size == 3);
    assert_tail_only_output(replay);

    const auto emitted = replay.finish(35);
    assert((emitted == std::vector<llama_token> { 31, 32, 33, 34, 35 }));
    assert(!replay.active());
}

static void test_abort_cleanup() {
    server_spec_forced_replay replay;
    replay.begin({ 41, 42 }, 3);
    replay.clear();

    assert(!replay.active());
    assert(replay.tokens.empty());
    assert(replay.original_draft_size == 0);
    assert(replay.accepted_draft_size == 0);
}

int main() {
    test_zero_accepted_draft_tokens();
    test_partial_acceptance();
    test_full_acceptance();
    test_abort_cleanup();
    return 0;
}
