# OpenAI prompt-cache affinity inventory

Implementation plan:
[OPENAI_PROMPT_CACHE_AFFINITY_IMPLEMENTATION_PLAN.md](OPENAI_PROMPT_CACHE_AFFINITY_IMPLEMENTATION_PLAN.md)

## Objective

Accept OpenAI's top-level `prompt_cache_key` on Chat Completions and Responses
requests and use it as a soft affinity hint for llama-server's existing resident
slot and RAM prompt-cache selection.

OpenAI contract: <https://developers.openai.com/api/docs/guides/prompt-caching>

The key does not authorize KV reuse. The tokenized prompt's actual common prefix
remains authoritative. An empty key preserves the current scheduler exactly.

## Existing machinery

No new OpenAI route or proxy layer is required:

- `server_chat_convert_responses_to_chatcmpl()` starts from a copy of the
  Responses body, so `prompt_cache_key` already survives Responses-to-Chat
  conversion.
- `oaicompat_chat_params_parse()` copies unconsumed top-level properties into
  the llama request object.
- `handle_completions_impl()` creates the tasks after tokenization.
- `server_context::select_slots()` already owns resident-slot selection by
  prompt similarity and LRU.
- `server_prompt_cache::take()` already owns RAM-cache selection by actual token
  prefix.
- `server_prompt_cache::apply()` already owns target/draft/spec state restore.
- OpenAI-compatible usage responses already expose `cached_tokens` for Chat
  Completions and Responses.

## Missing function-level work

### 1. Parse and carry the OpenAI field

- Add `task_params::prompt_cache_key` in `tools/server/server-task.h`.
- Add a `field_str("prompt_cache_key", params.prompt_cache_key)` entry in
  `server_schema::make_llama_cmpl_schema()`.

This is the only required request-parsing change. Both `/v1/chat/completions`
and `/v1/responses` already deliver the field to the schema.

`server_task::add_child()` already copies `task_params`, so parallel completion
children inherit the key without another API.

### 2. Carry affinity with resident and RAM prompt state

- Add `server_slot::prompt_cache_key` beside the resident `server_prompt`.
- Add `server_prompt_cache_state::prompt_cache_key` beside its saved prompt and
  state bytes.
- Extend `server_prompt_cache::alloc()` to receive and copy the resident slot's
  key when `server_slot::prompt_save()` creates an entry.

Do not put the key inside `server_prompt`. `server_prompt::clear()` is also used
for in-request token/KV mutations such as context shifting and full-prefill
fallbacks; those operations must not erase the current request's affinity.

`attach_prepared_slot()` is the correct new-request handoff: displaced state has
already been saved before it runs, and it can replace the resident key with
`prepared.task->params.prompt_cache_key`. `server_prompt_cache::apply()` remains
unaware of affinity and cannot overwrite the new request's key.

`server_task::add_child()` already copies the key in `task_params`, and each
child passes through `attach_prepared_slot()`. `copy_state_to()` therefore stays
focused on inference state and does not acquire a second identity rule.

Clear the resident key whenever the resident inference state is deliberately
discarded: explicit slot erase, manual slot restore (the disk format carries no
affinity), child-slot release, exceptional speculative-cycle abort, and unified
KV idle offload after the keyed state has been saved to RAM. Emergency unified-KV
eviction and whole-context decode-error cleanup also clear it. Ordinary completed
parent release and in-request prompt mutation keep the key.

### 3. Add resident-slot affinity selection

Extend `server_context::select_slots(const server_task &)` with one selection
pass before ordinary prompt-similarity/LRU selection:

1. Explicit llama.cpp `id_slot`, when supplied, remains the strongest request.
2. When `cache_prompt` is enabled and `prompt_cache_key` is non-empty, inspect
   idle slots whose resident `server_slot::prompt_cache_key` matches.
3. If several match, choose the one with the longest actual token prefix.
4. If none match, run the existing similarity and LRU paths unchanged.

The selected slot still enters the existing resident-prefix reconciliation, so
a reused or stale key can cause a full prefill but cannot cause incorrect KV
reuse.

### 4. Add RAM-cache affinity selection

Extend `server_prompt_cache::take()` to receive the incoming cache key:

```cpp
std::unique_ptr<server_prompt_cache_state> take(
        const server_prompt & prompt,
        const server_tokens & tokens_new,
        const std::string & cache_key);
```

For a non-empty key, first compare entries with the same stored key and choose
the best actual common prefix using the existing keep/similarity calculations.
If no matching-key entry is usable, fall back to the current global search.
An empty key executes the current algorithm exactly.

Do not change `apply()`: it remains a policy-free mechanical restore. Admission
sets the incoming key after the restore result is known.

### 5. Make the admission handoff explicit

Update the existing cache transaction inside
`server_context::process_single_task()`:

1. save displaced prompt with its old resident key;
2. call the key-aware `server_prompt_cache::take()`;
3. let `attach_prepared_slot()` replace each incoming slot's resident key;
4. reset/restore using the existing transaction;
5. continue to pre-decode, where actual token-prefix reconciliation remains
   authoritative.

No changes belong in speculative decoding, KV serialization, the OpenAI
response formatter, or `X-Conversation-Id` stream-resumption code.

## Required proof

- Chat Completions carries `prompt_cache_key` into `task_params`.
- Responses carries the same field through conversion into `task_params`.
- A later request with the same key prefers the corresponding idle slot.
- Multiple states with the same key choose the longest actual prefix.
- A stale key with a different prompt performs ordinary prefix reconciliation;
  it never treats the key as a cache hit.
- A matching RAM entry is preferred and restored through the existing
  target-first path.
- When no matching key exists, ordinary LCP/LRU and RAM-cache selection remain
  unchanged.
- Omitting the field is byte-for-byte equivalent at the API and scheduling
  level to current behavior.
- `n_cmpl > 1` children inherit the key without being pinned to a physical
  slot.

## Deliberately separate OpenAI cache features

This integration does not implement OpenAI's newer explicit cache-breakpoint
model, `prompt_cache_options`, cache-write accounting, or TTL controls. Those
features describe which rendered prefixes are written and retained. The work
above only adds the standard affinity connection to llama.cpp's existing
automatic exact-prefix cache.

`X-Conversation-Id` also remains separate: it identifies a resumable HTTP
stream, not prompt-cache affinity.
