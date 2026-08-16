#include "server-inference-snapshot.h"

namespace server_inference {

stream_snapshot project_current_task(const raw_stream_state & raw) {
    stream_snapshot result = raw.passive;

    const bool output_visible     = result.attached && result.live && result.state == lifecycle::GENERATING;
    result.output_committed_count = output_visible ? raw.raw_n_decoded : 0;
    result.pending_sampled_input  = output_visible ? raw.raw_sampled_input : false;
    return result;
}

}  // namespace server_inference
