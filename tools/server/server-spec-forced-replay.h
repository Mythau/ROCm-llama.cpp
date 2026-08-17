#pragma once

#include "llama.h"

#include <cstddef>
#include <utility>
#include <vector>

struct server_spec_forced_replay {
    std::vector<llama_token> tokens;
    size_t original_draft_size = 0;
    size_t accepted_draft_size = 0;

    bool active() const {
        return !tokens.empty();
    }

    void begin(std::vector<llama_token> authoritative_tokens, size_t draft_size) {
        tokens = std::move(authoritative_tokens);
        original_draft_size = draft_size;
        accepted_draft_size = tokens.size() - 1;
    }

    bool requests_output(size_t token_index) const {
        return token_index + 1 == tokens.size();
    }

    std::vector<llama_token> finish(llama_token tail) {
        auto result = std::move(tokens);
        result.push_back(tail);
        tokens.clear();
        original_draft_size = 0;
        accepted_draft_size = 0;
        return result;
    }

    void clear() {
        tokens.clear();
        original_draft_size = 0;
        accepted_draft_size = 0;
    }
};
