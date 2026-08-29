#pragma once

#if defined(GGML_USE_HIP)
// Only the backend factory/free/copy implementation sees this extension. The
// shared ggml_backend_cuda_context definition and all kernel offsets are unchanged.
struct ggml_hip_staging_slot {
    int source_device;
    int destination_device;
    void * data = nullptr;
    size_t capacity = 0;
    hipEvent_t staged = nullptr;
    hipEvent_t uploaded = nullptr;
    uint64_t copies = 0;
    uint64_t bytes = 0;
    uint64_t allocations = 0;
    uint64_t growth_waits = 0;

    ggml_hip_staging_slot(int source, int destination) :
        source_device(source), destination_device(destination) {
        CUDA_CHECK(hipSetDevice(source_device));
        CUDA_CHECK(hipEventCreateWithFlags(&staged, hipEventDisableTiming));
        CUDA_CHECK(hipSetDevice(destination_device));
        CUDA_CHECK(hipEventCreateWithFlags(&uploaded, hipEventDisableTiming));
    }

    ~ggml_hip_staging_slot() {
        CUDA_CHECK(hipSetDevice(destination_device));
        if (copies != 0) {
            // The last H2D is the last reader of the pinned allocation.
            CUDA_CHECK(hipEventSynchronize(uploaded));
        }
        if (data != nullptr) {
            CUDA_CHECK(hipHostFree(data));
        }
        CUDA_CHECK(hipEventDestroy(uploaded));
        CUDA_CHECK(hipSetDevice(source_device));
        CUDA_CHECK(hipEventDestroy(staged));
    }

    void copy(hipStream_t source_stream, hipStream_t destination_stream,
              const void * source, void * destination, size_t size) {
        if (size > capacity) {
            CUDA_CHECK(hipSetDevice(destination_device));
            if (copies != 0) {
                CUDA_CHECK(hipEventSynchronize(uploaded));
                ++growth_waits;
            }
            if (data != nullptr) {
                CUDA_CHECK(hipHostFree(data));
            }
            CUDA_CHECK(hipHostMalloc(&data, size, hipHostMallocPortable));
            capacity = size;
            ++allocations;
        }

        CUDA_CHECK(hipSetDevice(source_device));
        if (copies != 0) {
            // Refill only after the previous destination upload read the slot.
            // Queue the old-generation wait before re-recording uploaded below.
            CUDA_CHECK(hipStreamWaitEvent(source_stream, uploaded, 0));
        }
        CUDA_CHECK(hipMemcpyAsync(data, source, size, hipMemcpyDeviceToHost, source_stream));
        CUDA_CHECK(hipEventRecord(staged, source_stream));

        CUDA_CHECK(hipSetDevice(destination_device));
        CUDA_CHECK(hipStreamWaitEvent(destination_stream, staged, 0));
        CUDA_CHECK(hipMemcpyAsync(destination, data, size, hipMemcpyHostToDevice, destination_stream));
        CUDA_CHECK(hipEventRecord(uploaded, destination_stream));
        ++copies;
        bytes += size;
    }
};

struct ggml_backend_cuda_transfer_context : ggml_backend_cuda_context {
    bool event_staging = getenv("GGML_HIP_EVENT_STAGING") != nullptr;
    bool staging_log = getenv("GGML_HIP_EVENT_STAGING_LOG") != nullptr;
    std::map<int, std::unique_ptr<ggml_hip_staging_slot>> incoming_staging;

    explicit ggml_backend_cuda_transfer_context(int device) : ggml_backend_cuda_context(device) {}

    ~ggml_backend_cuda_transfer_context() {
        if (staging_log) {
            for (const auto & entry : incoming_staging) {
                const auto & slot = *entry.second;
                GGML_LOG_INFO("HIP_EVENT_STAGE_SUMMARY src=%d dst=%d copies=%" PRIu64
                    " bytes=%" PRIu64 " capacity=%zu allocations=%" PRIu64 " growth_waits=%" PRIu64 "\n",
                    slot.source_device, slot.destination_device, slot.copies, slot.bytes,
                    slot.capacity, slot.allocations, slot.growth_waits);
            }
        }
        // Finish slot cleanup before the base context destroys its streams.
        incoming_staging.clear();
        ggml_cuda_set_device(device);
    }

    bool copy_from(ggml_backend_cuda_context * source_context, const ggml_tensor * source,
                   ggml_tensor * destination) {
        if (!event_staging) {
            return false;
        }
        const size_t size = ggml_nbytes(destination);
        if (size == 0) {
            return true;
        }
        const int source_device = ggml_cuda_get_physical_device(source_context->device);
        auto & slot = incoming_staging[source_device];
        if (!slot) {
            slot = std::make_unique<ggml_hip_staging_slot>(source_device, ggml_cuda_get_physical_device(device));
        }
        const hipStream_t source_stream = source_context->stream();
        const hipStream_t destination_stream = stream();
        slot->copy(source_stream, destination_stream, source->data, destination->data, size);
        if (staging_log) {
            GGML_LOG_INFO("HIP_EVENT_STAGE src=%d dst=%d name=%s bytes=%zu generation=%" PRIu64 "\n",
                slot->source_device, slot->destination_device, source->name, size, slot->copies);
        }
        return true;
    }
};
#else
using ggml_backend_cuda_transfer_context = ggml_backend_cuda_context;
#endif
