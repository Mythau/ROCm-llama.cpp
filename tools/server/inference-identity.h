#pragma once

#include <cstdint>
#include <tuple>

namespace inference::identity {

struct stream_key {
    int32_t slot_id;
    int64_t task_id;
};

inline bool operator==(const stream_key & lhs, const stream_key & rhs) {
    return lhs.slot_id == rhs.slot_id && lhs.task_id == rhs.task_id;
}

inline bool operator!=(const stream_key & lhs, const stream_key & rhs) {
    return !(lhs == rhs);
}

inline bool operator<(const stream_key & lhs, const stream_key & rhs) {
    return std::tie(lhs.slot_id, lhs.task_id) < std::tie(rhs.slot_id, rhs.task_id);
}

struct cohort_id {
    uint64_t value;
};

inline bool operator==(cohort_id lhs, cohort_id rhs) {
    return lhs.value == rhs.value;
}

struct iteration_id {
    uint64_t value;
};

inline bool operator==(iteration_id lhs, iteration_id rhs) {
    return lhs.value == rhs.value;
}

}  // namespace inference::identity
