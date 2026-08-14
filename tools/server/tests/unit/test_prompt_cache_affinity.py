import pytest

from utils import ServerPreset


def chat_request(server, key, system_prompt, user_prompt, id_slot=None):
    data = {
        "model": "tinyllama-2",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "max_tokens": 1,
        "cache_prompt": True,
        "prompt_cache_key": key,
    }
    if id_slot is not None:
        data["id_slot"] = id_slot
    return server.make_request("POST", "/v1/chat/completions", data=data)


def response_request(server, key, text, id_slot=None):
    data = {
        "model": "tinyllama-2",
        "input": text,
        "max_output_tokens": 1,
        "cache_prompt": True,
        "prompt_cache_key": key,
    }
    if id_slot is not None:
        data["id_slot"] = id_slot
    return server.make_request("POST", "/v1/responses", data=data)


def test_chat_prompt_cache_key_prefers_resident_slot_and_prefix_remains_authoritative():
    server = ServerPreset.tinyllama2()
    server.debug = True
    server.no_cache_idle_slots = True
    server.start()

    first = chat_request(
        server,
        "conversation-a",
        "You are following conversation A.",
        "Alpha one two three four five six seven eight.",
        id_slot=0,
    )
    second = chat_request(
        server,
        "conversation-b",
        "You are following conversation B.",
        "Beta one two three four five six seven eight.",
        id_slot=1,
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.body["__verbose"]["id_slot"] != second.body["__verbose"]["id_slot"]

    continuation = chat_request(
        server,
        "conversation-a",
        "You are following conversation A.",
        "Alpha one two three four five six seven eight. Continue from there.",
    )
    assert continuation.status_code == 200
    assert continuation.body["__verbose"]["id_slot"] == first.body["__verbose"]["id_slot"]
    assert continuation.body["usage"]["prompt_tokens_details"]["cached_tokens"] > 0

    changed = chat_request(
        server,
        "conversation-a",
        "This is an unrelated system instruction.",
        "Completely different subject matter with no conversation continuation.",
    )
    assert changed.status_code == 200
    assert changed.body["__verbose"]["id_slot"] == first.body["__verbose"]["id_slot"]
    assert changed.body["usage"]["prompt_tokens_details"]["cached_tokens"] < changed.body["usage"]["prompt_tokens"]


def test_responses_prompt_cache_key_restores_ram_entry_after_unified_kv_offload():
    server = ServerPreset.tinyllama2()
    server.kv_unified = True
    server.cache_ram = 100
    server.start()

    first = response_request(
        server,
        "response-a",
        "Alpha one two three four five six seven eight nine ten.",
        id_slot=0,
    )
    second = response_request(
        server,
        "response-b",
        "Beta one two three four five six seven eight nine ten.",
        id_slot=1,
    )
    restored = response_request(
        server,
        "response-a",
        "Alpha one two three four five six seven eight nine ten. Continue.",
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert restored.status_code == 200
    assert restored.body["usage"]["input_tokens_details"]["cached_tokens"] > 0


@pytest.mark.parametrize("path,body", [
    ("/v1/chat/completions", {
        "messages": [{"role": "user", "content": "Hello"}],
        "max_tokens": 1,
        "prompt_cache_key": 123,
    }),
    ("/v1/responses", {
        "input": "Hello",
        "max_output_tokens": 1,
        "prompt_cache_key": 123,
    }),
])
def test_prompt_cache_key_requires_a_string(path, body):
    server = ServerPreset.tinyllama2()
    server.start()

    response = server.make_request("POST", path, data=body)
    assert response.status_code == 400
