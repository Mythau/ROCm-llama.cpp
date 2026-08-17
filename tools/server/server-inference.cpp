#include "server-inference.h"

namespace server_inference {

std::vector<stream_snapshot> snapshot_reader::read(const std::vector<server_slot> &) const {
    // Dormant Phase 2 translator: raw slot/task facts are materialized here, not
    // in server-context.cpp. No slot/task/runtime mutation, no queue access, no
    // static or history state. The real slot-fact mapping is wired in Step 12.
    return {};
}

}  // namespace server_inference
