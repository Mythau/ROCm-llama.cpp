# OpenAI prompt-cache affinity patch notes

## Objective

Let independent clients or agents return to their own cached conversation state
without knowing llama-server slot IDs. A client sends the same
`prompt_cache_key` with successive full-conversation requests; llama-server then
prefers the resident slot or RAM prompt entry created by that key's earlier
request. If the token prefix still matches, only the new suffix needs to be
evaluated instead of prefilling the full conversation again.

This is especially useful on a multi-slot server, where ordinary LRU or
prefix-only selection can otherwise send a returning agent to a slot containing
another caller's cache state. The key supplies caller/conversation affinity; it
does not replace token-prefix validation or reserve capacity. All clients still
connect to the same llama-server port; slots are internal execution contexts,
not separate network endpoints.

## What changed

- `POST /v1/chat/completions` and `POST /v1/responses` accept a string
  `prompt_cache_key`.
- The key is carried with the request, the selected resident slot and saved RAM
  prompt-cache entries.
- Idle resident slots with the same key are considered before ordinary
  prefix-similarity and LRU selection.
- RAM prompt-cache lookup first searches compatible entries with the same key,
  then falls back to the existing global prefix-based search.
- The actual tokenized common prefix remains the authority for KV reuse. A key
  does not make incompatible cache state valid.
- A key is soft affinity, not a reservation. If the matching slot is busy, the
  request can use another available slot. Concurrent requests sharing a key are
  not serialized.
- Empty or absent keys preserve existing llama-server behaviour.
- Affinity is cleared when its resident prompt state is explicitly erased,
  replaced, invalidated or discarded.

## OpenCode compatibility

The patched OpenAI-compatible endpoint works with OpenCode 1.18.18 using
`@ai-sdk/openai-compatible` and `/v1/chat/completions` streaming.

Validation completed on the local four-slot Q35B ROCm server:

- Four concurrent OpenCode agents generated simultaneously through all four
  server slots and completed normally.
- A five-request direct OpenAI-compatible test admitted four requests and
  deferred the fifth until a slot was released; all five returned HTTP 200.
- Direct keyed follow-up requests selected the same resident slots and reported
  cached prompt tokens.
- No cross-request marker leakage or HIP, OOM, NaN, allocator or decode errors
  were observed in these runs.

OpenCode itself was used to validate the ordinary OpenAI-compatible connection
and concurrent streaming. The `prompt_cache_key` affinity path was validated by
direct API tests; OpenCode does not currently prove that it emits a distinct
`prompt_cache_key` for each of its sessions.

The tested server was bound to localhost and had no API key configured. This
patch does not add authentication, caller authentication, key issuance,
rotation, revocation or an identity-to-affinity mapping. `prompt_cache_key` is
untrusted routing metadata and must not be treated as a credential.

Upstream llama-server has static `--api-key` and `--api-key-file` checks, but
those facilities were not evaluated as part of this patch. The fork maintainer
does not claim the security expertise required to design or audit a new
authentication system safely. An unauthenticated server should not be exposed
beyond a trusted local environment.

## Validation status

This feature works in the tested configurations, but it has not been thoroughly
validated across clients, models, cache layouts or failure modes. Treat it as a
working integration patch rather than a compatibility guarantee.

Focused prompt-affinity tests and the existing prompt-cache regression tests
pass. Production validation so far is limited to the local Q35B Q8_0 ROCm
configuration with four partitioned-KV slots and the separate unified/RAM-cache
restore exercises already documented in this fork.

## Limitations

- No hard slot ownership or per-client reservation.
- No request queue identity beyond the supplied key.
- No fork-specific authentication or API-key management. The documented and
  tested invocation is unauthenticated and localhost-only.
- No OpenAI explicit cache breakpoints, `prompt_cache_options` or cache TTL
  controls.
- `X-Conversation-Id` remains stream-resumption state and is not used for prompt
  affinity.
- A matching key cannot override token-prefix validation.
- Concurrent requests with the same key may occupy different slots.
- Behaviour with clients that omit `prompt_cache_key` is unchanged.
