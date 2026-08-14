# OpenAI prompt-cache affinity implementation plan

Source inventory: [OPENAI_PROMPT_CACHE_AFFINITY.md](OPENAI_PROMPT_CACHE_AFFINITY.md)

OpenAI contract: <https://developers.openai.com/api/docs/guides/prompt-caching>

## Goal

Accept OpenAI's top-level `prompt_cache_key` and use it as soft affinity for
llama-server's existing resident slots and RAM prompt cache.

The key chooses where to look first. The tokenized prompt's actual prefix still
decides whether KV state can be reused. A missing or empty key preserves current
behaviour.

This plan does not implement explicit cache breakpoints,
`prompt_cache_options`, TTL, cache-write accounting, `previous_response_id`, or
stream resumption. It does not change speculative decoding or KV serialization.

## Authority map

| Concern | Owner |
|---|---|
| Incoming OpenAI field | `task_params` and completion schema |
| Live affinity | `server_slot` |
| Saved affinity | `server_prompt_cache_state` |
| Resident-slot choice | `server_context::select_slots()` |
| RAM-entry choice | `server_prompt_cache::take()` |
| KV correctness | Existing token-prefix reconciliation and cache `apply()` |
| HTTP stream resumption | Existing `X-Conversation-Id` code, unchanged |

## OA-01 — Request field and task transport

Status: [x]

### Changes

- Add `std::string prompt_cache_key` to `task_params`.
- Add `field_str("prompt_cache_key", params.prompt_cache_key)` to
  `server_schema::make_llama_cmpl_schema()`.
- Do not add the key to `task_params::to_json()`, completion responses, metrics,
  or ordinary logs. OpenAI documents user IDs and session IDs as common values,
  so it is request-routing metadata rather than response data.

No route-specific parser is needed:

- Chat Completions already passes unknown top-level fields into the completion
  schema.
- Responses conversion begins with a copy of the request body, so the field
  survives `server_chat_convert_responses_to_chatcmpl()`.
- `server_task::add_child()` copies `task_params`, so `n_cmpl` children inherit
  the key.

### Proof

- Chat Completions string field reaches `task_params`.
- Responses string field reaches `task_params` after conversion.
- A non-string value receives the existing schema's invalid-request response.
- No field produces the same parsed task defaults as before.
- Compile `server-context` and `llama-server`.

### Review

Review the complete diff for transport only. Reject route-specific duplicate
parsing, new key validation rules beyond the user-facing string type, and any
response/log exposure.

## OA-02 — Affinity metadata lifecycle

Status: [x]

Depends on: OA-01

### Changes

- Add `server_slot::prompt_cache_key` beside the resident prompt.
- Add `server_prompt_cache_state::prompt_cache_key` beside the saved prompt and
  state data.
- Extend `server_prompt_cache::alloc()` to accept the resident key.
- Pass the key from `server_slot::prompt_save()` into `alloc()`.
- In `attach_prepared_slot()`, replace the resident key with the newly attached
  task's key. This occurs after displaced state has been saved.
- Clear the resident key whenever resident inference state is deliberately
  discarded: explicit slot erase, manual slot restore, child-slot release,
  exceptional speculative-cycle abort, and unified-KV idle offload after the
  keyed state has been saved to RAM. Emergency unified-KV eviction and
  whole-context decode-error cleanup also clear it. Disk slot files do not
  serialize affinity.
- Keep the resident key across normal completion/release.

Do not place the key in `server_prompt`. `server_prompt::clear()` is used during
context shift and other mutations inside a request; those operations must not
erase the current request's identity.

Do not add a key-to-slot map. Slots and RAM states already own the only copies
needed.

### Proof

- Saving an idle/resident slot copies its old key into the RAM state.
- Attaching a new task replaces the slot key only after old-state capture.
- Parent and completion children receive the request key through their own
  attach operations.
- Context shift and full-prefill fallback retain the current request key.
- Explicit erase, manual restore, child discard, exceptional abort, and unified
  idle offload leave no stale resident affinity.
- Compile `server-context` and `llama-server`.

### Review

Trace every key assignment and clear site. Confirm there is one live owner and
one saved owner, no duplicate registry, and no change to prompt/KV serialization.

## OA-03 — Resident-slot affinity

Status: [x]

Depends on: OA-02

### Changes

Extend `server_context::select_slots(const server_task &)` without moving its
scheduling authority:

1. Preserve explicit `id_slot` precedence.
2. If the incoming request has `cache_prompt=true` and a non-empty key, inspect
   idle slots carrying the same key.
3. Choose the matching-key slot with the longest actual common token prefix.
   Preserve deterministic existing slot iteration for ties.
4. If no matching-key slot is idle, continue through the existing prompt
   similarity and LRU logic unchanged.
5. Derive the existing save/load cache intention from how much of the selected
   resident prompt would be retained; do not treat key equality as a cache hit.

A busy matching slot does not defer or pin the request. Another idle slot may
serve it, which is required for concurrent agents using the same session key.

### Proof

- Explicit `id_slot` still wins.
- Same-key idle slot is preferred and exact prefix reuse is reported normally.
- Of several same-key idle slots, the longest actual prefix wins.
- A stale same-key slot with zero matching tokens performs an ordinary full
  prefill; it does not reuse incorrect state.
- A busy same-key slot does not block admission when another slot is free.
- Empty key and `cache_prompt=false` retain existing LCP/LRU selection.
- Parent/child capacity selection remains unchanged.

### Review

Review scheduling outcomes, not merely code shape. Confirm that affinity is a
preference, physical slot IDs remain internal unless explicitly requested, and
token-prefix logic remains the only reuse authority.

## OA-04 — RAM prompt-cache affinity

Status: [x]

Depends on: OA-02

May be implemented in parallel with OA-03 after OA-02.

### Changes

Extend `server_prompt_cache::take()` with the incoming key:

```cpp
std::unique_ptr<server_prompt_cache_state> take(
        const server_prompt & prompt,
        const server_tokens & tokens_new,
        const std::string & prompt_cache_key);
```

Selection algorithm:

1. Compute the current resident prompt as the existing baseline.
2. For a non-empty key, search saved entries with the same key using the
   existing common-prefix, keep-fraction, similarity, and improvement rules.
3. If a usable same-key entry improves on the resident baseline, take the best
   one.
4. Otherwise run the existing global search unchanged.
5. Empty key enters the existing global search directly.

A local helper/lambda may share the existing comparison loop between the keyed
and global passes. Do not add a second cache container or duplicate saved state.

Update the admission call in `process_single_task()` to pass the prepared
parent task's key. Leave `server_prompt_cache::apply()` unchanged: it remains a
policy-free, target-first mechanical restore.

### Proof

- Matching-key entry is preferred when it is a usable improvement.
- Multiple matching-key entries choose the best actual prefix.
- An unusable or stale matching-key entry falls back to global prefix search.
- No matching key behaves exactly like the existing cache.
- Empty key follows the existing algorithm exactly.
- The selected entry is still consumed once and restored through existing
  target/draft/spec handling.
- Target restore failure and optional speculative-state failure keep their
  current behaviour.

### Review

Compare the empty-key path line-for-line with the previous selection semantics.
Confirm that `take()` only selects ownership and that no affinity policy enters
`alloc()`, `apply()`, KV serialization, or speculative state handling.

## OA-05 — Integrated behaviour and documentation

Status: [x]

Depends on: OA-03 and OA-04

### Tests

Add focused cases to the existing server Python test infrastructure:

- Chat Completions same-key resident reuse.
- Responses same-key resident reuse.
- Two different keys occupying two slots, followed by the correct keyed
  continuation.
- Busy same-key request served concurrently by another free slot.
- Same key with changed prompt: no false cached-token count and coherent output.
- RAM-cache churn followed by same-key restoration.
- Same-key RAM candidates select the longest real prefix.
- No matching key falls back to existing global prefix reuse.
- Omitted key preserves existing cached-token and slot-selection tests.
- `n_cmpl > 1` children do not acquire physical-slot pinning.
- Explicit erase/manual restore remove stale affinity.
- Child discard, exceptional abort, and unified idle offload remove stale
  resident affinity while retaining the saved RAM-entry key.

Use existing `cached_tokens`, completion output, and slot IDs available in test
responses to prove behaviour. Do not add a public affinity-debug endpoint or a
new telemetry framework solely for these tests.

### Documentation

- Document `prompt_cache_key` for `/v1/chat/completions` and `/v1/responses`.
- State that it is a soft routing hint, not a slot ID and not proof of a hit.
- State that callers should still send the full conversation/prompt and enable
  prompt caching.
- State that `X-Conversation-Id` remains resumable-stream identity.
- List explicit cache breakpoints, `prompt_cache_options`, and TTL as separate,
  unsupported OpenAI cache features.

### Final validation

- Compile the normal server target.
- Run the focused affinity tests and existing prompt-cache tests.
- Run one two-slot manual smoke using the OpenAI-compatible endpoint.
- Inspect `git diff --check` and the complete diff.
- Perform an independent material review of API compatibility, slot scheduling,
  RAM selection, and stale-key correctness before commit.

Completed on 2026-08-14:

- `server-context` and `llama-server` compiled and linked successfully.
- A two-slot Chat Completions smoke preferred the keyed resident slot, reused
  88 prompt tokens on continuation, and treated a changed prompt as an ordinary
  partial-prefix case rather than a key-authorized hit.
- A unified-KV Responses smoke restored the keyed RAM entry and reused 51
  prompt tokens.
- Non-string keys returned the existing HTTP 400 schema error on both routes.
- Existing no-key Chat cache accounting remained exactly `0, 76, 51, 47`, and
  the existing unified RAM-cache flow still restored 175 tokens while evaluating
  one token.
- Full source review confirmed explicit-slot precedence, busy-key fallback,
  child-group scheduling, target-first cache application, and key clearing at
  every resident-state discard site.

## Dependency graph

```text
OA-01 request transport
  -> OA-02 metadata lifecycle
       -> OA-03 resident-slot affinity --\
       -> OA-04 RAM-cache affinity -----+-> OA-05 integration/tests/docs
```

OA-03 and OA-04 have separate authorities and can proceed independently after
OA-02. OA-05 is the first point that treats both affinity paths as one feature.

## Completion criteria

The feature is complete when an ordinary OpenAI-compatible client can send a
stable `prompt_cache_key` without knowing `id_slot`; llama-server prefers the
correct resident or RAM-cached conversation state, serves concurrent requests
without key-based pinning, verifies the actual token prefix before every reuse,
and behaves exactly as it did when the field is omitted.
