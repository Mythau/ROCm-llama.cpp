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
