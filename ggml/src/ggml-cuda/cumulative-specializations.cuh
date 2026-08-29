// Clean structural selectors for the validated gfx1100 recurrent-decode specializations.
#pragma once

void ggml_cuda_op_gated_delta_net_fused_cache_direct(
    ggml_backend_cuda_context & ctx, ggml_tensor * dst,
    ggml_cuda_gated_delta_net_fused_cache cache);
void ggml_cuda_op_ssm_conv_split_state_fused(
    ggml_backend_cuda_context & ctx, ggml_tensor * conv,
    ggml_tensor * state_input, ggml_tensor * new_input,
    ggml_tensor * state_copy, ggml_tensor * silu);

#ifdef GGML_CUMULATIVE_VERIFY
static std::atomic<size_t> cumulative_counts[6][GGML_CUDA_MAX_DEVICES] {};
extern "C" __declspec(dllexport) void ggml_cumulative_count(int kind, int device) {
    cumulative_counts[kind][device].fetch_add(1, std::memory_order_relaxed);
}
struct ggml_cumulative_reporter {
    ~ggml_cumulative_reporter() {
        std::fprintf(stderr,
            "cumulative_selection qkv=%zu/%zu direct_skip=%zu/%zu concat=%zu/%zu copy=%zu/%zu conv=%zu/%zu direct_launch=%zu/%zu\n",
            cumulative_counts[0][0].load(), cumulative_counts[0][1].load(),
            cumulative_counts[1][0].load(), cumulative_counts[1][1].load(),
            cumulative_counts[2][0].load(), cumulative_counts[2][1].load(),
            cumulative_counts[3][0].load(), cumulative_counts[3][1].load(),
            cumulative_counts[4][0].load(), cumulative_counts[4][1].load(),
            cumulative_counts[5][0].load(), cumulative_counts[5][1].load());
    }
};
static ggml_cumulative_reporter cumulative_reporter;
#define GGML_CUMULATIVE_COUNT(kind, device) ggml_cumulative_count((kind), (device))
#else
#define GGML_CUMULATIVE_COUNT(kind, device) ((void) 0)
#endif

static bool ggml_cuda_cumulative_rdna3(const ggml_backend_cuda_context * ctx) {
    return GGML_CUDA_CC_IS_RDNA3_0(ggml_cuda_info().devices[ctx->device].cc);
}

static bool ggml_cuda_cumulative_alias_chain(const ggml_tensor * tensor, const ggml_tensor * root) {
    if (tensor == nullptr) {
        return false;
    }
    if (tensor == root || tensor->view_src == root) {
        return true;
    }
    switch (tensor->op) {
        case GGML_OP_VIEW:
        case GGML_OP_RESHAPE:
        case GGML_OP_PERMUTE:
        case GGML_OP_TRANSPOSE:
            return ggml_cuda_cumulative_alias_chain(tensor->src[0], root);
        default:
            return false;
    }
}

static bool ggml_cuda_cumulative_direct_shape(const ggml_tensor * get_rows, const ggml_tensor * gdn) {
    if (get_rows == nullptr || gdn == nullptr || get_rows->op != GGML_OP_GET_ROWS ||
        get_rows->type != GGML_TYPE_F32 || (get_rows->flags & GGML_TENSOR_FLAG_OUTPUT) ||
        ggml_nelements(get_rows) != 128 * 128 * 32 ||
        get_rows->ne[1] != 1 || get_rows->ne[2] != 1 || get_rows->ne[3] != 1 ||
        get_rows->src[0] == nullptr || get_rows->src[1] == nullptr ||
        ggml_nelements(get_rows->src[1]) != 1 || !ggml_is_contiguous(get_rows) ||
        gdn->op != GGML_OP_GATED_DELTA_NET || ggml_get_op_params_i32(gdn, 0) != 1) {
        return false;
    }
    const ggml_tensor * v = gdn->src[2];
    const ggml_tensor * state = gdn->src[5];
    return v != nullptr && state != nullptr &&
        v->ne[0] == 128 && v->ne[1] == 32 && v->ne[2] == 1 && v->ne[3] == 1 &&
        state->ne[0] == 128 && state->ne[1] == 128 && state->ne[2] == 32 && state->ne[3] == 1 &&
        ggml_cuda_cumulative_alias_chain(state, get_rows);
}

static bool ggml_cuda_cumulative_only_gdn_consumes(
        const ggml_cgraph * graph, const ggml_tensor * get_rows, const ggml_tensor * gdn) {
    for (int i = 0; i < graph->n_nodes; ++i) {
        const ggml_tensor * node = graph->nodes[i];
        if (ggml_cuda_is_view_or_noop(node)) {
            continue;
        }
        for (int s = 0; s < GGML_MAX_SRC; ++s) {
            if (ggml_cuda_cumulative_alias_chain(node->src[s], get_rows) && node != gdn) {
                return false;
            }
        }
    }
    return true;
}

static const ggml_tensor * ggml_cuda_cumulative_direct_get_rows(
        const ggml_cgraph * graph, int gdn_index, ggml_cuda_gated_delta_net_fused_cache * cache_out,
        int * skip_out) {
    const ggml_tensor * gdn = graph->nodes[gdn_index];
    ggml_cuda_gated_delta_net_fused_cache cache;
    const int skip = ggml_cuda_try_gdn_cache_fusion(graph, gdn_index, cache);
    if (skip <= 0 || cache.slot_stride != 0) {
        return nullptr;
    }
    for (int i = gdn_index - 1; i >= 0; --i) {
        const ggml_tensor * candidate = graph->nodes[i];
        if (!ggml_cuda_cumulative_direct_shape(candidate, gdn)) {
            continue;
        }
        const ggml_tensor * state_copy = graph->nodes[gdn_index + skip];
        if (state_copy->op != GGML_OP_CPY || state_copy->src[1] == nullptr ||
            candidate->src[0]->buffer != state_copy->src[1]->buffer) {
            return nullptr;
        }
        *cache_out = cache;
        *skip_out  = skip;
        return candidate;
    }
    return nullptr;
}

struct ggml_cuda_cumulative_conv_match {
    ggml_tensor * concat = nullptr;
    ggml_tensor * copy   = nullptr;
    ggml_tensor * conv   = nullptr;
    ggml_tensor * silu   = nullptr;
    int concat_index = -1;
    int copy_index   = -1;
    int conv_index   = -1;
    int silu_index   = -1;
};

static ggml_tensor * ggml_cuda_cumulative_concat_root(ggml_tensor * tensor) {
    if (tensor == nullptr) {
        return nullptr;
    }
    if (tensor->op == GGML_OP_CONCAT) {
        return tensor;
    }
    switch (tensor->op) {
        case GGML_OP_VIEW:
        case GGML_OP_RESHAPE:
        case GGML_OP_PERMUTE:
        case GGML_OP_TRANSPOSE:
            return ggml_cuda_cumulative_concat_root(tensor->src[0]);
        default:
            return nullptr;
    }
}

static bool ggml_cuda_cumulative_match_conv(
        ggml_cgraph * graph, ggml_tensor * concat, ggml_cuda_cumulative_conv_match & match) {
    if (concat == nullptr || concat->op != GGML_OP_CONCAT || concat->type != GGML_TYPE_F32 ||
        concat->src[0] == nullptr || concat->src[1] == nullptr ||
        concat->ne[0] != 8192 || concat->ne[1] != 4 || concat->ne[2] != 1 || concat->ne[3] != 1 ||
        concat->src[0]->type != GGML_TYPE_F32 || concat->src[1]->type != GGML_TYPE_F32 ||
        concat->src[0]->ne[0] != 8192 || concat->src[0]->ne[1] != 3 ||
        concat->src[0]->ne[2] != 1 || concat->src[0]->ne[3] != 1 ||
        concat->src[1]->ne[0] != 8192 || concat->src[1]->ne[1] != 1 ||
        concat->src[1]->ne[2] != 1 || concat->src[1]->ne[3] != 1) {
        return false;
    }

    for (int i = 0; i < graph->n_nodes; ++i) {
        ggml_tensor * node = graph->nodes[i];
        if (node == concat) {
            match.concat = node;
            match.concat_index = i;
        } else if (node->op == GGML_OP_CPY && node->src[0] != nullptr &&
                   ggml_cuda_cumulative_concat_root(node->src[0]) == concat) {
            if (match.copy != nullptr || node->src[1] == nullptr ||
                node->src[0]->type != GGML_TYPE_F32 ||
                ggml_nelements(node->src[0]) != 3 * 8192 ||
                ggml_nelements(node->src[1]) != 3 * 8192 ||
                node->src[0]->view_offs != concat->nb[1] ||
                node->src[1]->data == concat->src[0]->data) {
                return false;
            }
            match.copy = node;
            match.copy_index = i;
        } else if (node->op == GGML_OP_SSM_CONV && node->src[0] == concat) {
            if (match.conv != nullptr || node->src[1] == nullptr ||
                ggml_ssm_conv_get_layout(node) != GGML_SSM_CONV_LAYOUT_CHANNELS_MAJOR ||
                node->src[1]->type != GGML_TYPE_F32 || node->src[1]->ne[0] != 4 ||
                node->src[1]->ne[1] != 8192 || node->ne[0] != 8192 ||
                node->ne[1] != 1 || node->ne[2] != 1 || node->ne[3] != 1) {
                return false;
            }
            match.conv = node;
            match.conv_index = i;
        }
    }
    if (match.concat == nullptr || match.copy == nullptr || match.conv == nullptr ||
        !(match.concat_index < match.copy_index && match.copy_index < match.conv_index) ||
        match.conv_index + 1 >= graph->n_nodes) {
        return false;
    }
    match.silu = graph->nodes[match.conv_index + 1];
    match.silu_index = match.conv_index + 1;
    if (match.silu->op != GGML_OP_UNARY || ggml_get_unary_op(match.silu) != GGML_UNARY_OP_SILU ||
        match.silu->src[0] != match.conv || match.silu->type != GGML_TYPE_F32 ||
        !ggml_are_same_shape(match.silu, match.conv)) {
        return false;
    }

    // CONCAT may feed only its update view and this convolution; the raw convolution only feeds SiLU.
    for (int i = 0; i < graph->n_nodes; ++i) {
        const ggml_tensor * node = graph->nodes[i];
        if (ggml_cuda_is_view_or_noop(node)) {
            continue;
        }
        for (int s = 0; s < GGML_MAX_SRC; ++s) {
            if (ggml_cuda_cumulative_alias_chain(node->src[s], concat) &&
                node != match.copy && node != match.conv) {
                return false;
            }
            if (node->src[s] == match.conv && node != match.silu) {
                return false;
            }
        }
    }
    return true;
}

static bool ggml_cuda_cumulative_find_conv(
        ggml_cgraph * graph, ggml_tensor * node, ggml_cuda_cumulative_conv_match & match) {
    ggml_tensor * concat = nullptr;
    if (node->op == GGML_OP_CONCAT) {
        concat = node;
    } else if (node->op == GGML_OP_CPY) {
        concat = ggml_cuda_cumulative_concat_root(node->src[0]);
    } else if (node->op == GGML_OP_SSM_CONV) {
        concat = node->src[0] != nullptr && node->src[0]->op == GGML_OP_CONCAT ? node->src[0] : nullptr;
    } else if (node->op == GGML_OP_UNARY && node->src[0] != nullptr &&
               node->src[0]->op == GGML_OP_SSM_CONV) {
        concat = node->src[0]->src[0] != nullptr && node->src[0]->src[0]->op == GGML_OP_CONCAT
            ? node->src[0]->src[0] : nullptr;
    }
    return concat != nullptr && ggml_cuda_cumulative_match_conv(graph, concat, match);
}

static bool ggml_cuda_cumulative_try_compute_qkv(
        ggml_backend_cuda_context * ctx, ggml_cgraph * graph, int index) {
#ifdef GGML_CUMULATIVE_DISABLE_QKV
    GGML_UNUSED(ctx);
    GGML_UNUSED(graph);
    GGML_UNUSED(index);
    return false;
#else
    if (!ggml_cuda_cumulative_rdna3(ctx)) {
        return false;
    }
    ggml_tensor * node = graph->nodes[index];
    if (node->op != GGML_OP_MUL_MAT || node->src[0] == nullptr || node->src[1] == nullptr ||
        node->src[0]->type != GGML_TYPE_Q8_0 || node->src[1]->type != GGML_TYPE_F32 ||
        node->type != GGML_TYPE_F32 || node->src[0]->ne[0] != 2048 ||
        node->src[0]->ne[1] != 8192 || node->src[0]->ne[2] != 1 || node->src[0]->ne[3] != 1 ||
        node->src[1]->ne[0] != 2048 || node->src[1]->ne[1] != 1 ||
        node->src[1]->ne[2] != 1 || node->src[1]->ne[3] != 1) {
        return false;
    }
    for (int i = index + 1; i < graph->n_nodes; ++i) {
        if (graph->nodes[i]->op != GGML_OP_CONCAT ||
            !ggml_cuda_cumulative_alias_chain(graph->nodes[i]->src[1], node)) {
            continue;
        }
        ggml_cuda_cumulative_conv_match match;
        if (ggml_cuda_cumulative_match_conv(graph, graph->nodes[i], match)) {
            ggml_cuda_mul_mat_vec_q(*ctx, node->src[0], node->src[1], nullptr, node, nullptr, true);
            return true;
        }
    }
    return false;
#endif
}

static bool ggml_cuda_cumulative_should_skip(
        ggml_backend_cuda_context * ctx, ggml_cgraph * graph, int index) {
    if (!ggml_cuda_cumulative_rdna3(ctx)) {
        return false;
    }
    ggml_tensor * node = graph->nodes[index];
#ifndef GGML_CUMULATIVE_DISABLE_DIRECT
    if (node->op == GGML_OP_GET_ROWS) {
        for (int i = index + 1; i < graph->n_nodes; ++i) {
            if (graph->nodes[i]->op != GGML_OP_GATED_DELTA_NET) {
                continue;
            }
            ggml_cuda_gated_delta_net_fused_cache cache;
            int skip = 0;
            if (ggml_cuda_cumulative_direct_get_rows(graph, i, &cache, &skip) == node) {
                GGML_CUMULATIVE_COUNT(1, ctx->device);
                return true;
            }
        }
    }
#endif
#ifndef GGML_CUMULATIVE_DISABLE_CONV
    if (node->op == GGML_OP_CONCAT || node->op == GGML_OP_CPY ||
        node->op == GGML_OP_SSM_CONV || node->op == GGML_OP_UNARY) {
        ggml_cuda_cumulative_conv_match match;
        if (ggml_cuda_cumulative_find_conv(graph, node, match)) {
            if (node == match.concat) {
                ggml_cuda_op_ssm_conv_split_state_fused(
                    *ctx, match.conv, match.concat->src[0], match.concat->src[1], match.copy, match.silu);
                GGML_CUMULATIVE_COUNT(2, ctx->device);
                GGML_CUMULATIVE_COUNT(4, ctx->device);
                return true;
            }
            if (node == match.copy) {
                GGML_CUMULATIVE_COUNT(3, ctx->device);
                return true;
            }
            if (node == match.conv || node == match.silu) {
                return true;
            }
        }
    }
#endif
    return false;
}

// Returns -1 when this is not one of the cumulative specializations.
static int ggml_cuda_cumulative_try_fuse(
        ggml_backend_cuda_context * ctx, ggml_cgraph * graph, int index) {
    if (!ggml_cuda_cumulative_rdna3(ctx)) {
        return -1;
    }
    ggml_tensor * node = graph->nodes[index];
#ifndef GGML_CUMULATIVE_DISABLE_DIRECT
    if (node->op == GGML_OP_GATED_DELTA_NET) {
        ggml_cuda_gated_delta_net_fused_cache cache;
        int skip = 0;
        if (ggml_cuda_cumulative_direct_get_rows(graph, index, &cache, &skip) != nullptr) {
            ggml_cuda_op_gated_delta_net_fused_cache_direct(*ctx, node, cache);
            GGML_CUMULATIVE_COUNT(5, ctx->device);
            return skip;
        }
    }
#endif
#ifndef GGML_CUMULATIVE_DISABLE_CONV
    if (node->op == GGML_OP_SSM_CONV) {
        ggml_cuda_cumulative_conv_match match;
        if (ggml_cuda_cumulative_find_conv(graph, node, match) && match.conv == node) {
            ggml_cuda_op_ssm_conv_split_state_fused(
                *ctx, node, match.concat->src[0], match.concat->src[1], match.copy, match.silu);
            GGML_CUMULATIVE_COUNT(4, ctx->device);
            return match.silu_index - index;
        }
    }
#endif
    return -1;
}

// One immutable execution plan per graph evaluation. Selection is derived once from
// the graph topology; the execution loop performs only short pointer lookups.
struct ggml_cuda_cumulative_plan {
    struct direct_entry {
        ggml_tensor * get_rows;
        ggml_tensor * gdn;
        ggml_cuda_gated_delta_net_fused_cache cache;
        int skip;
    };
    ggml_backend_cuda_context * ctx;
    std::vector<ggml_tensor *> qkv;
    std::vector<direct_entry> direct;
    std::vector<ggml_cuda_cumulative_conv_match> conv;

    ggml_cuda_cumulative_plan(ggml_backend_cuda_context * context, ggml_cgraph * graph) : ctx(context) {
        if (!ggml_cuda_cumulative_rdna3(ctx)) {
            return;
        }

        const auto alias_origin = [](ggml_tensor * tensor) {
            while (tensor != nullptr) {
                switch (tensor->op) {
                    case GGML_OP_VIEW:
                    case GGML_OP_RESHAPE:
                    case GGML_OP_PERMUTE:
                    case GGML_OP_TRANSPOSE:
                        tensor = tensor->src[0];
                        continue;
                    default:
                        return tensor;
                }
            }
            return tensor;
        };
        const auto find_conv = [&](ggml_tensor * concat) -> ggml_cuda_cumulative_conv_match * {
            for (auto & match : conv) {
                if (match.concat == concat) {
                    return &match;
                }
            }
            return nullptr;
        };

        // First pass: exact split-input CONCAT producers.
        for (int i = 0; i < graph->n_nodes; ++i) {
            ggml_tensor * node = graph->nodes[i];
            if (node->op == GGML_OP_CONCAT && node->type == GGML_TYPE_F32 &&
                node->src[0] != nullptr && node->src[1] != nullptr &&
                node->ne[0] == 8192 && node->ne[1] == 4 && node->ne[2] == 1 && node->ne[3] == 1 &&
                node->src[0]->type == GGML_TYPE_F32 && node->src[1]->type == GGML_TYPE_F32 &&
                node->src[0]->ne[0] == 8192 && node->src[0]->ne[1] == 3 &&
                node->src[0]->ne[2] == 1 && node->src[0]->ne[3] == 1 &&
                node->src[1]->ne[0] == 8192 && node->src[1]->ne[1] == 1 &&
                node->src[1]->ne[2] == 1 && node->src[1]->ne[3] == 1) {
                ggml_cuda_cumulative_conv_match match;
                match.concat = node;
                match.concat_index = i;
                conv.push_back(match);
            }
        }

        // Second pass: attach the unique update copy and SSM consumer without rescanning the graph per layer.
        for (int i = 0; i < graph->n_nodes; ++i) {
            ggml_tensor * node = graph->nodes[i];
            if (node->op == GGML_OP_CPY && node->src[0] != nullptr && node->src[1] != nullptr) {
                ggml_tensor * concat = alias_origin(node->src[0]);
                ggml_cuda_cumulative_conv_match * match = find_conv(concat);
                if (match != nullptr && match->copy == nullptr &&
                    node->src[0]->type == GGML_TYPE_F32 &&
                    ggml_nelements(node->src[0]) == 3 * 8192 &&
                    ggml_nelements(node->src[1]) == 3 * 8192 &&
                    node->src[0]->view_offs == concat->nb[1] &&
                    node->src[1]->data != concat->src[0]->data) {
                    match->copy = node;
                    match->copy_index = i;
                }
            } else if (node->op == GGML_OP_SSM_CONV && node->src[0] != nullptr &&
                       node->src[0]->op == GGML_OP_CONCAT && node->src[1] != nullptr) {
                ggml_cuda_cumulative_conv_match * match = find_conv(node->src[0]);
                if (match != nullptr && match->conv == nullptr &&
                    ggml_ssm_conv_get_layout(node) == GGML_SSM_CONV_LAYOUT_CHANNELS_MAJOR &&
                    node->src[1]->type == GGML_TYPE_F32 && node->src[1]->ne[0] == 4 &&
                    node->src[1]->ne[1] == 8192 && node->ne[0] == 8192 &&
                    node->ne[1] == 1 && node->ne[2] == 1 && node->ne[3] == 1) {
                    match->conv = node;
                    match->conv_index = i;
                }
            }
        }

        // Complete and retain only the exact dependency chain.
        for (auto & match : conv) {
            if (match.copy == nullptr || match.conv == nullptr ||
                !(match.concat_index < match.copy_index && match.copy_index < match.conv_index) ||
                match.conv_index + 1 >= graph->n_nodes) {
                match.concat = nullptr;
                continue;
            }
            match.silu = graph->nodes[match.conv_index + 1];
            match.silu_index = match.conv_index + 1;
            if (match.silu->op != GGML_OP_UNARY || ggml_get_unary_op(match.silu) != GGML_UNARY_OP_SILU ||
                match.silu->src[0] != match.conv || match.silu->type != GGML_TYPE_F32 ||
                !ggml_are_same_shape(match.silu, match.conv)) {
                match.concat = nullptr;
            }
        }
        conv.erase(std::remove_if(conv.begin(), conv.end(),
            [](const ggml_cuda_cumulative_conv_match & match) { return match.concat == nullptr; }), conv.end());

        // Direct-state ownership follows the GDN state alias directly to its GET_ROWS producer.
        for (int i = 0; i < graph->n_nodes; ++i) {
            ggml_tensor * node = graph->nodes[i];
            if (node->op == GGML_OP_GATED_DELTA_NET && node->src[5] != nullptr) {
                ggml_tensor * get_rows = alias_origin(node->src[5]);
                ggml_cuda_gated_delta_net_fused_cache cache;
                int skip = 0;
                if (ggml_cuda_cumulative_direct_shape(get_rows, node) &&
                    ggml_cuda_try_gdn_cache_fusion(graph, i, cache) > 0 && cache.slot_stride == 0) {
                    skip = ggml_cuda_try_gdn_cache_fusion(graph, i, cache);
                    const ggml_tensor * state_copy = graph->nodes[i + skip];
                    if (state_copy->op == GGML_OP_CPY && state_copy->src[1] != nullptr &&
                        get_rows->src[0]->buffer == state_copy->src[1]->buffer) {
                        direct.push_back({get_rows, node, cache, skip});
                    }
                }
            }
        }

        // QKV is the exact Q8 projection whose output aliases the split convolution's new input.
        for (int i = 0; i < graph->n_nodes; ++i) {
            ggml_tensor * node = graph->nodes[i];
            if (node->op != GGML_OP_MUL_MAT || node->src[0] == nullptr || node->src[1] == nullptr ||
                node->src[0]->type != GGML_TYPE_Q8_0 || node->src[1]->type != GGML_TYPE_F32 ||
                node->type != GGML_TYPE_F32 || node->src[0]->ne[0] != 2048 ||
                node->src[0]->ne[1] != 8192 || node->src[0]->ne[2] != 1 || node->src[0]->ne[3] != 1 ||
                node->src[1]->ne[0] != 2048 || node->src[1]->ne[1] != 1 ||
                node->src[1]->ne[2] != 1 || node->src[1]->ne[3] != 1) {
                continue;
            }
            for (const auto & match : conv) {
                if (alias_origin(match.concat->src[1]) == node) {
                    qkv.push_back(node);
                    break;
                }
            }
        }
    }

    bool dispatch_or_skip(ggml_tensor * node) const {
        for (ggml_tensor * selected : qkv) {
            if (selected == node) {
                ggml_cuda_mul_mat_vec_q(*ctx, node->src[0], node->src[1], nullptr, node, nullptr, true);
                return true;
            }
        }
        for (const auto & selected : direct) {
            if (selected.get_rows == node) {
                GGML_CUMULATIVE_COUNT(1, ctx->device);
                return true;
            }
        }
        for (const auto & selected : conv) {
            if (selected.concat == node) {
                ggml_cuda_op_ssm_conv_split_state_fused(
                    *ctx, selected.conv, selected.concat->src[0], selected.concat->src[1],
                    selected.copy, selected.silu);
                GGML_CUMULATIVE_COUNT(2, ctx->device);
                GGML_CUMULATIVE_COUNT(4, ctx->device);
                return true;
            }
            if (selected.copy == node) {
                GGML_CUMULATIVE_COUNT(3, ctx->device);
                return true;
            }
            if (selected.conv == node || selected.silu == node) {
                return true;
            }
        }
        return false;
    }

    int try_fuse(ggml_tensor * node) const {
        for (const auto & selected : direct) {
            if (selected.gdn == node) {
                ggml_cuda_op_gated_delta_net_fused_cache_direct(*ctx, node, selected.cache);
                GGML_CUMULATIVE_COUNT(5, ctx->device);
                return selected.skip;
            }
        }
        return -1;
    }
};
