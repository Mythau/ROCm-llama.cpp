#include "speculative.h"

#include <algorithm>
#include <cstring>

struct common_speculative_hidden_archive_block {
    llama_seq_id seq_id;
    llama_pos pos_first;
    int32_t row_count;
    int32_t n_embd;
    ggml_type storage_type;

    std::vector<llama_token> tokens;
    std::vector<float> rows;

    size_t retained_bytes() const {
        return sizeof(*this) +
            tokens.capacity() * sizeof(tokens[0]) +
            rows.capacity() * sizeof(rows[0]);
    }
};

struct common_speculative_hidden_archive_slice {
    std::shared_ptr<const common_speculative_hidden_archive_block> block;
    int32_t offset;
    int32_t count;
};

struct common_speculative_hidden_archive {
    uint64_t id;
    llama_seq_id seq_id;
    int32_t n_embd;
    ggml_type storage_type;
    std::vector<common_speculative_hidden_archive_slice> blocks;
};

struct common_speculative_hidden_archive_builder {
    uint64_t id;
    llama_seq_id seq_id;
    int32_t n_embd;
    ggml_type storage_type;
    std::vector<common_speculative_hidden_archive_slice> blocks;
};

static int64_t archive_row_count(const common_speculative_hidden_archive & archive) {
    int64_t result = 0;
    for (const auto & cur : archive.blocks) {
        result += cur.count;
    }
    return result;
}

static llama_pos archive_pos_first(const common_speculative_hidden_archive & archive) {
    if (archive.blocks.empty()) {
        return -1;
    }
    const auto & first = archive.blocks.front();
    return first.block->pos_first + first.offset;
}

static llama_pos archive_pos_end(const common_speculative_hidden_archive & archive) {
    if (archive.blocks.empty()) {
        return -1;
    }
    const auto & last = archive.blocks.back();
    return last.block->pos_first + last.offset + last.count - 1;
}

static size_t archive_retained_bytes(const common_speculative_hidden_archive & archive) {
    size_t result = sizeof(archive) + archive.blocks.capacity() * sizeof(archive.blocks[0]);
    for (const auto & cur : archive.blocks) {
        result += cur.block->retained_bytes();
    }
    return result;
}

void common_speculative_hidden_archive_builder_deleter::operator()(
        common_speculative_hidden_archive_builder * builder) const {
    delete builder;
}

common_speculative_hidden_archive_builder_ptr common_speculative_hidden_archive_builder_init(
        uint64_t id,
        llama_seq_id seq_id,
        int32_t n_embd,
        ggml_type storage_type,
        common_speculative_hidden_archive_ref prefix) {
    GGML_ASSERT(id != 0);
    GGML_ASSERT(seq_id >= 0);
    GGML_ASSERT(n_embd > 0);
    GGML_ASSERT(storage_type == GGML_TYPE_F32);

    auto result = common_speculative_hidden_archive_builder_ptr(
            new common_speculative_hidden_archive_builder {
                id,
                seq_id,
                n_embd,
                storage_type,
                {},
            });

    if (prefix) {
        GGML_ASSERT(prefix->n_embd == n_embd);
        GGML_ASSERT(prefix->storage_type == storage_type);
        result->blocks = prefix->blocks;
    }

    return result;
}

void common_speculative_hidden_archive_builder_append(
        common_speculative_hidden_archive_builder * builder,
        llama_pos pos_first,
        const llama_token * tokens,
        const float * rows,
        int32_t row_count) {
    GGML_ASSERT(builder != nullptr);
    GGML_ASSERT(pos_first >= 0);
    GGML_ASSERT(tokens != nullptr);
    GGML_ASSERT(rows != nullptr);
    GGML_ASSERT(row_count > 0);

    if (!builder->blocks.empty()) {
        const auto & last = builder->blocks.back();
        const llama_pos pos_next = last.block->pos_first + last.offset + last.count;
        GGML_ASSERT(pos_first == pos_next);
    }

    auto block = std::make_shared<common_speculative_hidden_archive_block>(
            common_speculative_hidden_archive_block {
                builder->seq_id,
                pos_first,
                row_count,
                builder->n_embd,
                builder->storage_type,
                std::vector<llama_token>(tokens, tokens + row_count),
                std::vector<float>((size_t) row_count * builder->n_embd),
            });

    std::memcpy(block->rows.data(), rows,
            (size_t) row_count * builder->n_embd * sizeof(float));

    builder->blocks.push_back({ std::move(block), 0, row_count });
}

common_speculative_hidden_archive_ref common_speculative_hidden_archive_builder_finalize(
        common_speculative_hidden_archive_builder_ptr builder) {
    GGML_ASSERT(builder != nullptr);
    GGML_ASSERT(!builder->blocks.empty());

    return std::make_shared<const common_speculative_hidden_archive>(
            common_speculative_hidden_archive {
                builder->id,
                builder->seq_id,
                builder->n_embd,
                builder->storage_type,
                std::move(builder->blocks),
            });
}

common_speculative_hidden_archive_ref common_speculative_hidden_archive_prefix(
        common_speculative_hidden_archive_ref archive,
        int64_t row_count,
        uint64_t id) {
    GGML_ASSERT(archive != nullptr);
    GGML_ASSERT(id != 0);
    GGML_ASSERT(row_count > 0);
    GGML_ASSERT(row_count <= archive_row_count(*archive));

    std::vector<common_speculative_hidden_archive_slice> blocks;
    int64_t remaining = row_count;

    for (const auto & cur : archive->blocks) {
        if (remaining == 0) {
            break;
        }

        const int32_t count = (int32_t) std::min<int64_t>(remaining, cur.count);
        blocks.push_back({ cur.block, cur.offset, count });
        remaining -= count;
    }

    return std::make_shared<const common_speculative_hidden_archive>(
            common_speculative_hidden_archive {
                id,
                archive->seq_id,
                archive->n_embd,
                archive->storage_type,
                std::move(blocks),
            });
}

common_speculative_hidden_archive_info common_speculative_hidden_archive_get_info(
        const common_speculative_hidden_archive_ref & archive) {
    GGML_ASSERT(archive != nullptr);

    return {
        archive->id,
        archive->seq_id,
        archive_pos_first(*archive),
        archive_pos_end(*archive),
        archive_row_count(*archive),
        archive->n_embd,
        archive->storage_type,
        archive_retained_bytes(*archive),
    };
}

int32_t common_speculative_hidden_archive_read(
        const common_speculative_hidden_archive_ref & archive,
        common_speculative_hidden_archive_cursor & cursor,
        int32_t max_rows,
        llama_token * tokens,
        llama_pos * positions,
        float * rows) {
    GGML_ASSERT(archive != nullptr);
    GGML_ASSERT(max_rows > 0);
    GGML_ASSERT(tokens != nullptr);
    GGML_ASSERT(positions != nullptr);
    GGML_ASSERT(rows != nullptr);

    int32_t result = 0;
    while (result < max_rows && cursor.block < archive->blocks.size()) {
        const auto & cur = archive->blocks[cursor.block];
        const int32_t available = cur.count - cursor.offset;
        const int32_t count = std::min(max_rows - result, available);
        const int32_t source = cur.offset + cursor.offset;

        std::memcpy(tokens + result,
                cur.block->tokens.data() + source,
                (size_t) count * sizeof(tokens[0]));
        std::memcpy(rows + (size_t) result * archive->n_embd,
                cur.block->rows.data() + (size_t) source * archive->n_embd,
                (size_t) count * archive->n_embd * sizeof(rows[0]));

        for (int32_t i = 0; i < count; ++i) {
            positions[result + i] = cur.block->pos_first + source + i;
        }

        result += count;
        cursor.offset += count;
        if (cursor.offset == cur.count) {
            cursor.block++;
            cursor.offset = 0;
        }
    }

    return result;
}
