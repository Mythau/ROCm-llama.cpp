#pragma once

// Passive, history-free snapshot translator. Dormant in Phase 2: no live server
// source may include this header, and the class is compiled into the dormant
// contract test target only.

#include "server-inference-snapshot.h"

#include <vector>

struct server_slot;

namespace server_inference {

class snapshot_reader {
public:
    snapshot_reader() = default;

    // const view over server slots: read-only, no history, no queue access.
    std::vector<stream_snapshot> read(const std::vector<server_slot> & slots) const;
};

}  // namespace server_inference
