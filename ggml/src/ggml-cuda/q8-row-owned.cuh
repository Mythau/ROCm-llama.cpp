// Exact Q8_0 2048x8192 single-column row ownership for RDNA3.0.
// The host selector in mmvq.cu makes this kernel unreachable on other devices/shapes.
__global__ __launch_bounds__(256) void q8_0_2048x8192_row_owned_rdna3(
        const void * weights, const block_q8_1 * activation, float * output) {
#if defined(RDNA3_0)
    const int lane = threadIdx.x;
    const int wave = threadIdx.y;
    const int row  = 8 * blockIdx.x + wave;
    float sum = 0.0f;

    // Preserve the original eight partial sums and their addition order.
#pragma unroll
    for (int part = 0; part < 8; ++part) {
        const int block = part * 8 + lane / 4;
        float partial = vec_dot_q8_0_q8_1(
            weights, activation + block, row * 64 + block, 2 * (lane % 4));
        asm volatile("" : "+v"(partial));
        sum += partial;
    }
    sum = warp_reduce_sum<32>(sum);
    if (lane == 0) {
        output[row] = sum;
    }
#endif
}

// Experimental decode-only Qwen3.6 routed W1/W3 + SwiGLU mapping for gfx1100.
// This ownership mapping is retained for controlled comparison, but measured
// slower than the generic kernel and must be enabled explicitly.
#if defined(GGML_EXACT_W13_ENABLE)
__global__ __launch_bounds__(256) void q8_0_moe_w13_2048x512_swiglu_row_owned_rdna3(
        const void * up_weights, const void * gate_weights,
        const block_q8_1 * activations, const int32_t * ids, float * output
#ifdef GGML_MOE_PROFILE
        , uint64_t * clock_values
#endif
        ) {
#if defined(RDNA3_0)
#ifdef GGML_MOE_PROFILE
    const bool clock_first = blockIdx.x == 0 && blockIdx.y == 0 && threadIdx.x == 0 && threadIdx.y == 0;
    const bool clock_last = blockIdx.x + 1 == gridDim.x && blockIdx.y + 1 == gridDim.y &&
        threadIdx.x == 0 && threadIdx.y == 0;
    if (clock_values != nullptr && clock_first) clock_values[0] = wall_clock64();
#endif
    constexpr int blocks_per_row = 2048 / QK8_0;
    constexpr int rows_per_expert = 512;

    const int lane = threadIdx.x;
    const int wave = threadIdx.y;
    const int row  = 8 * blockIdx.x + wave;
    const int slot = blockIdx.y;
    const int expert = ids[slot];

    const block_q8_1 * activation = activations;
    const int expert_block = expert * rows_per_expert * blocks_per_row;
    const int row_block = expert_block + row * blocks_per_row;

    float up_sum = 0.0f;
    float gate_sum = 0.0f;
#pragma unroll
    for (int part = 0; part < 8; ++part) {
        const int block = part * 8 + lane / 4;
        const int q_index = 2 * (lane % 4);
        float up_partial = vec_dot_q8_0_q8_1(
            up_weights, activation + block, row_block + block, q_index);
        float gate_partial = vec_dot_q8_0_q8_1(
            gate_weights, activation + block, row_block + block, q_index);
        asm volatile("" : "+v"(up_partial), "+v"(gate_partial));
        up_sum += up_partial;
        gate_sum += gate_partial;
    }

    up_sum = warp_reduce_sum<32>(up_sum);
    gate_sum = warp_reduce_sum<32>(gate_sum);
    if (lane == 0) {
        output[slot * rows_per_expert + row] = up_sum * ggml_cuda_op_silu_single(gate_sum);
    }
#ifdef GGML_MOE_PROFILE
    if (clock_values != nullptr && clock_last) clock_values[1] = wall_clock64();
#endif
#else
    GGML_UNUSED(up_weights);
    GGML_UNUSED(gate_weights);
    GGML_UNUSED(activations);
    GGML_UNUSED(ids);
    GGML_UNUSED(output);
#endif
}
#endif

// Exact decode-only Qwen3.6 routed W2 shape on gfx1100.
// blockIdx.y owns one route slot and threadIdx.y owns one output row.
__global__ __launch_bounds__(256) void q8_0_moe_w2_512x2048_row_owned_rdna3(
        const void * weights, const block_q8_1 * activations,
        const int32_t * ids, float * output
#ifdef GGML_MOE_PROFILE
        , uint64_t * clock_values
#endif
        ) {
#if defined(RDNA3_0)
#ifdef GGML_MOE_PROFILE
    const bool clock_first = blockIdx.x == 0 && blockIdx.y == 0 && threadIdx.x == 0 && threadIdx.y == 0;
    const bool clock_last = blockIdx.x + 1 == gridDim.x && blockIdx.y + 1 == gridDim.y &&
        threadIdx.x == 0 && threadIdx.y == 0;
    if (clock_values != nullptr && clock_first) clock_values[0] = wall_clock64();
#endif
    constexpr int blocks_per_row = 512 / QK8_0;
    constexpr int rows_per_expert = 2048;

    const int lane = threadIdx.x;
    const int wave = threadIdx.y;
    const int row  = 8 * blockIdx.x + wave;
    const int slot = blockIdx.y;
    const int expert = ids[slot];

    const block_q8_1 * activation = activations + slot * blocks_per_row;
    const int expert_block = expert * rows_per_expert * blocks_per_row;
    const int row_block = expert_block + row * blocks_per_row;

    float sum = 0.0f;
#pragma unroll
    for (int part = 0; part < 2; ++part) {
        const int block = part * 8 + lane / 4;
        float partial = vec_dot_q8_0_q8_1(
            weights, activation + block, row_block + block, 2 * (lane % 4));
        asm volatile("" : "+v"(partial));
        sum += partial;
    }

    sum = warp_reduce_sum<32>(sum);
    if (lane == 0) {
        output[slot * rows_per_expert + row] = sum;
    }
#ifdef GGML_MOE_PROFILE
    if (clock_values != nullptr && clock_last) clock_values[1] = wall_clock64();
#endif
#else
    GGML_UNUSED(weights);
    GGML_UNUSED(activations);
    GGML_UNUSED(ids);
    GGML_UNUSED(output);
#endif
}

// Exact decode-only Qwen3.6 W2, route weighting, and ordered top-8 reduction.
// threadIdx.y owns one final output row. Slots are evaluated in graph order so
// the route multiply and seven FP32 additions retain the predecessor rounding.
__global__ __launch_bounds__(256) void q8_0_moe_w2_512x2048_weighted_reduce_row_owned_rdna3(
        const void * weights, const block_q8_1 * activations,
        const int32_t * ids, const float * route_weights, float * output) {
#if defined(RDNA3_0)
    constexpr int blocks_per_row = 512 / QK8_0;
    constexpr int rows_per_expert = 2048;

    const int lane = threadIdx.x;
    const int wave = threadIdx.y;
    const int row  = 8 * blockIdx.x + wave;

    float accumulated = 0.0f;
#pragma unroll
    for (int slot = 0; slot < 8; ++slot) {
        const int expert = ids[slot];
        const block_q8_1 * activation = activations + slot * blocks_per_row;
        const int row_block = expert * rows_per_expert * blocks_per_row + row * blocks_per_row;

        float sum = 0.0f;
#pragma unroll
        for (int part = 0; part < 2; ++part) {
            const int block = part * 8 + lane / 4;
            float partial = vec_dot_q8_0_q8_1(
                weights, activation + block, row_block + block, 2 * (lane % 4));
            asm volatile("" : "+v"(partial));
            sum += partial;
        }

        sum = warp_reduce_sum<32>(sum);
        if (lane == 0) {
            float weighted = sum * route_weights[slot];
            asm volatile("" : "+v"(weighted));
            if (slot == 0) {
                accumulated = weighted;
            } else {
                accumulated += weighted;
                asm volatile("" : "+v"(accumulated));
            }
        }
    }

    if (lane == 0) {
        output[row] = accumulated;
    }
#else
    GGML_UNUSED(weights);
    GGML_UNUSED(activations);
    GGML_UNUSED(ids);
    GGML_UNUSED(route_weights);
    GGML_UNUSED(output);
#endif
}
