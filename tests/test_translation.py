import asyncio
import importlib.util
import json
import warnings
from contextlib import contextmanager
from pathlib import Path

from starlette.exceptions import StarletteDeprecationWarning

warnings.filterwarnings("ignore", category=StarletteDeprecationWarning)
from starlette.testclient import TestClient


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("proxy", ROOT / "proxy.py")
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)


@contextmanager
def image_policy(policy: str):
    old = proxy.config._data.get("inline_image_policy")
    proxy.config._data["inline_image_policy"] = policy
    try:
        yield
    finally:
        proxy.config._data["inline_image_policy"] = old


@contextmanager
def reasoning_policy(policy: str):
    old = proxy.config._data.get("reasoning_content_policy")
    proxy.config._data["reasoning_content_policy"] = policy
    try:
        yield
    finally:
        proxy.config._data["reasoning_content_policy"] = old


@contextmanager
def config_values(**values):
    old = {key: proxy.config._data.get(key) for key in values}
    proxy.config._data.update(values)
    try:
        yield
    finally:
        proxy.config._data.update(old)


def test_tool_schema_root_type_is_object():
    body = {
        "model": "claude-sonnet-4-5",
        "max_tokens": 16,
        "tools": [
            {
                "name": "web_search",
                "description": "search",
                "input_schema": {
                    "type": None,
                    "properties": {
                        "query": {"type": ["string", "null"]},
                    },
                },
            }
        ],
        "messages": [{"role": "user", "content": "hi"}],
    }

    converted = proxy.anthropic_to_openai(body, "deepseek-chat")
    params = converted["tools"][0]["function"]["parameters"]

    assert params["type"] == "object"
    assert params["properties"]["query"]["type"] == "string"


def test_model_alias_routes_to_configured_backend_model_even_with_force_model():
    with config_values(
        default_backend="custom",
        custom_api_key="test-key",
        custom_base_url="https://api.siliconflow.cn",
        force_model="wrong-global-force-model",
        model_aliases=[{
            "id": "byok-model-0001",
            "display_name": "Kimi K2.6 Pro++",
            "backend": "custom",
            "model": "Pro/moonshotai/Kimi-K2.6",
        }],
    ):
        backend = proxy.config.resolve_backend("byok-model-0001")

    assert backend["backend"] == "custom"
    assert backend["model"] == "Pro/moonshotai/Kimi-K2.6"
    assert backend["base_url"] == "https://api.siliconflow.cn/v1"
    assert backend["mode"] == "openai"


def test_deepseek_native_anthropic_mode_normalizes_base_url():
    with config_values(
        default_backend="deepseek",
        deepseek_api_key="test-key",
        deepseek_base_url="https://api.deepseek.com",
        deepseek_upstream_mode="anthropic",
        force_model="deepseek-chat",
    ):
        backend = proxy.config.resolve_backend("claude-sonnet-4-5")

    assert backend["backend"] == "deepseek"
    assert backend["mode"] == "anthropic"
    assert backend["base_url"] == "https://api.deepseek.com/anthropic/v1"
    assert backend["model"] == "deepseek-chat"


def test_max_tokens_cap_applies_to_openai_translation_and_native_body():
    body = {
        "model": "byok-model-0001",
        "max_tokens": 100000,
        "messages": [{"role": "user", "content": "hi"}],
    }
    with config_values(model_token_caps={"Pro/moonshotai/Kimi-K2.6": 8192}, default_max_tokens_cap=0):
        converted = proxy.anthropic_to_openai(
            body,
            "Pro/moonshotai/Kimi-K2.6",
            "custom",
            "https://api.siliconflow.cn/v1",
        )
        native = proxy.build_anthropic_backend_body(body, "Pro/moonshotai/Kimi-K2.6")

    assert converted["max_tokens"] == 8192
    assert native["max_tokens"] == 8192


def test_models_endpoint_can_return_only_third_party_aliases():
    client = TestClient(proxy.app)
    with config_values(
        model_list_mode="aliases",
        model_aliases=[{
            "id": "byok-model-0001",
            "display_name": "Kimi K2.6 Pro++",
            "backend": "custom",
            "model": "Pro/moonshotai/Kimi-K2.6",
        }],
    ):
        response = client.get("/v1/models")

    assert response.status_code == 200
    data = response.json()["data"]
    assert data == [{
        "id": "byok-model-0001",
        "type": "model",
        "display_name": "Kimi K2.6 Pro++",
    }]


def test_provider_presets_include_protocol_modes():
    client = TestClient(proxy.app)
    response = client.get("/api/provider-presets")

    assert response.status_code == 200
    presets = response.json()["presets"]
    assert presets["siliconflow_kimi"]["upstream_mode"] == "openai"
    assert presets["deepseek_anthropic"]["upstream_mode"] == "anthropic"
    assert presets["siliconflow_kimi"]["model_aliases"][0]["id"] == "claude-opus-4-8"


def test_ccswitch_style_models_url_candidates_strip_anthropic_suffixes():
    assert proxy.build_models_url_candidates("https://api.siliconflow.cn") == [
        "https://api.siliconflow.cn/v1/models",
    ]
    assert proxy.build_models_url_candidates("https://api.deepseek.com/anthropic") == [
        "https://api.deepseek.com/anthropic/v1/models",
        "https://api.deepseek.com/v1/models",
        "https://api.deepseek.com/models",
    ]
    assert proxy.build_models_url_candidates("https://open.bigmodel.cn/api/coding/paas/v4") == [
        "https://open.bigmodel.cn/api/coding/paas/v4/models",
        "https://open.bigmodel.cn/api/coding/paas/v4/v1/models",
    ]


def test_claude_compatible_aliases_show_provider_names_but_route_real_models():
    aliases = proxy.build_aliases_from_models(
        [
            {"id": "Pro/moonshotai/Kimi-K2.6", "display_name": "Kimi K2.6 Pro++"},
            {"id": "qwen-plus", "display_name": "Qwen Plus"},
        ],
        "custom",
        "claude_compatible",
    )

    assert aliases == [
        {
            "id": "claude-opus-4-8",
            "display_name": "Kimi K2.6 Pro++",
            "backend": "custom",
            "model": "Pro/moonshotai/Kimi-K2.6",
        },
        {
            "id": "claude-sonnet-5",
            "display_name": "Qwen Plus",
            "backend": "custom",
            "model": "qwen-plus",
        },
    ]


def test_profile_to_config_update_builds_menu_aliases_without_exposing_secret():
    profile = proxy.normalize_provider_profile({
        "id": "kimi-local",
        "label": "Kimi",
        "backend": "custom",
        "base_url": "https://api.siliconflow.cn",
        "upstream_mode": "openai",
        "api_key": "unit-test-secret",
        "default_model": "Pro/moonshotai/Kimi-K2.6",
        "models": [{"id": "Pro/moonshotai/Kimi-K2.6", "display_name": "Kimi K2.6 Pro++"}],
        "model_menu_strategy": "claude_compatible",
        "inline_image_policy": "preserve",
    })
    update = proxy.profile_to_config_update(profile)

    assert update["custom_api_key"] == "unit-test-secret"
    assert update["custom_base_url"] == "https://api.siliconflow.cn"
    assert update["model_aliases"][0]["id"] == "claude-opus-4-8"
    assert update["model_aliases"][0]["model"] == "Pro/moonshotai/Kimi-K2.6"
    assert update["inline_image_policy"] == "preserve"


def test_required_path_secret_protects_v1_and_does_not_log_secret():
    client = TestClient(proxy.app)
    proxy.request_log.clear()
    with config_values(proxy_auth_token="secret-test-token", proxy_auth_mode="required"):
        denied = client.get("/v1/models")
        allowed = client.get("/secret-test-token/v1/models")

    assert denied.status_code == 403
    assert denied.headers.get("connection") == "close"
    assert allowed.status_code == 200
    logs = json.dumps(proxy.request_log, ensure_ascii=False)
    assert "secret-test-token" not in logs
    assert "/v1/models" in logs


def test_siliconflow_forced_tool_choice_is_downgraded_to_auto():
    body = {
        "model": "claude-sonnet-4-5",
        "max_tokens": 16,
        "tools": [
            {
                "name": "python",
                "description": "run python",
                "input_schema": {"type": "object", "properties": {"code": {"type": "string"}}},
            }
        ],
        "tool_choice": {"type": "tool", "name": "python"},
        "messages": [{"role": "user", "content": "use python"}],
    }

    converted = proxy.anthropic_to_openai(
        body,
        "Pro/moonshotai/Kimi-K2.6",
        "custom",
        "https://api.siliconflow.cn/v1",
    )

    assert converted["tool_choice"] == "auto"


def test_openai_forced_tool_choice_keeps_function_choice():
    body = {
        "model": "claude-sonnet-4-5",
        "max_tokens": 16,
        "tools": [
            {
                "name": "python",
                "description": "run python",
                "input_schema": {"type": "object", "properties": {"code": {"type": "string"}}},
            }
        ],
        "tool_choice": {"type": "tool", "name": "python"},
        "messages": [{"role": "user", "content": "use python"}],
    }

    converted = proxy.anthropic_to_openai(body, "gpt-4o", "openai", "https://api.openai.com/v1")

    assert converted["tool_choice"] == {"type": "function", "function": {"name": "python"}}


def test_tool_results_follow_assistant_tool_calls_immediately():
    body = {
        "model": "claude-sonnet-4-5",
        "max_tokens": 16,
        "messages": [
            {
                "role": "assistant",
                "content": [
                    {
                        "type": "tool_use",
                        "id": "toolu_123",
                        "name": "web_search",
                        "input": {"query": "test"},
                    }
                ],
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "toolu_123",
                        "content": "result",
                    },
                    {"type": "text", "text": "continue"},
                ],
            },
        ],
    }

    converted = proxy.anthropic_to_openai(body, "deepseek-chat")
    messages = converted["messages"]

    assert messages[0]["role"] == "assistant"
    assert messages[0]["tool_calls"][0]["id"] == "toolu_123"
    assert messages[1] == {"role": "tool", "tool_call_id": "toolu_123", "content": "result"}
    assert messages[2] == {"role": "user", "content": "continue"}


def test_siliconflow_custom_preserves_inline_base64_images():
    body = {
        "model": "claude-sonnet-4-5",
        "max_tokens": 16,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "describe"},
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/png",
                            "data": "abc",
                        },
                    },
                ],
            }
        ],
    }

    with image_policy("auto"):
        converted = proxy.anthropic_to_openai(
            body,
            "Pro/moonshotai/Kimi-K2.6",
            "custom",
            "https://api.siliconflow.cn/v1",
        )

    content = converted["messages"][0]["content"]
    assert isinstance(content, list)
    assert content[0] == {"type": "text", "text": "describe"}
    assert content[1]["type"] == "image_url"
    assert content[1]["image_url"]["url"].startswith("data:image/png;base64,")


def test_deepseek_omits_images_for_text_only_backend():
    body = {
        "model": "claude-sonnet-4-5",
        "max_tokens": 16,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "describe"},
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/png",
                            "data": "abc",
                        },
                    },
                ],
            }
        ],
    }

    with image_policy("auto"):
        converted = proxy.anthropic_to_openai(body, "deepseek-chat", "deepseek", "https://api.deepseek.com/v1")
    content = converted["messages"][0]["content"]

    assert isinstance(content, str)
    assert "describe" in content
    assert "omitted" in content


def test_explicit_preserve_keeps_images_for_vision_backends():
    body = {
        "model": "claude-sonnet-4-5",
        "max_tokens": 16,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "describe"},
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": "abc",
                        },
                    },
                ],
            }
        ],
    }

    with image_policy("preserve"):
        converted = proxy.anthropic_to_openai(body, "vision-model", "custom", "https://provider.example.com/v1")

    content = converted["messages"][0]["content"]
    assert content[1]["type"] == "image_url"
    assert content[1]["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_reasoning_content_is_hidden_when_policy_is_never():
    response = {
        "choices": [{
            "message": {
                "content": "",
                "reasoning_content": "The user asked to continue. I should inspect files first.",
            },
            "finish_reason": "stop",
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20},
    }

    with reasoning_policy("never"):
        converted = proxy.openai_to_anthropic_response(response, "claude-sonnet-4-5", "msg_reason")

    assert converted["content"] == []


def test_trace_preamble_before_tool_call_is_hidden():
    trace = (
        'The user said "继续" (continue). The session was resumed, which means my Python kernel was reset. '
        "Files on disk are intact. Let me check what files I have and continue with the GO/KEGG enrichment analysis.\n\n"
        "I have gseapy installed now. Let me:\n"
        "1. First check what files are available\n"
        "2. Run the GO/KEGG enrichment analysis using gseapy\n"
        "3. Create the enrichment plots\n\n"
        "用户要求继续分析。会话已恢复，Python内核已重置但文件仍在。让我检查文件并继续GO/KEGG富集分析。"
    )
    response = {
        "choices": [{
            "message": {
                "content": trace,
                "tool_calls": [{
                    "id": "call_123",
                    "type": "function",
                    "function": {"name": "python", "arguments": "{\"code\":\"print(1)\"}"},
                }],
            },
            "finish_reason": "tool_calls",
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20},
    }

    converted = proxy.openai_to_anthropic_response(
        response,
        "claude-sonnet-4-5",
        "msg_trace",
        {"python": "python"},
    )

    assert len(converted["content"]) == 1
    assert converted["content"][0]["type"] == "tool_use"
    assert "The user said" not in json.dumps(converted, ensure_ascii=False)
    assert "用户要求继续分析" not in json.dumps(converted, ensure_ascii=False)


def test_kimi_embedded_tool_call_text_becomes_tool_use_block():
    args = {
        "human_description": "Building PPI network and calculating topology",
        "code": "import networkx as nx\nG = nx.Graph()\nprint(G.number_of_nodes())",
    }
    leaked = (
        "现在让我用networkx构建网络。"
        "<|tool_calls_section_begin|>"
        "<|tool_call_begin|>functions.python:47"
        "<|tool_call_argument_begin|>"
        f"{json.dumps(args, ensure_ascii=False)}"
        "<|tool_call_end|><|tool_calls_section_end|>"
    )
    response = {
        "choices": [{"message": {"content": leaked}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 20},
    }

    converted = proxy.openai_to_anthropic_response(
        response,
        "claude-sonnet-4-5",
        "msg_test",
        {"python": "python", "functions.python": "python"},
    )

    assert converted["stop_reason"] == "tool_use"
    assert len(converted["content"]) == 1
    tool_block = converted["content"][0]
    assert tool_block["type"] == "tool_use"
    assert tool_block["name"] == "python"
    assert tool_block["input"]["human_description"] == args["human_description"]
    assert "networkx" in tool_block["input"]["code"]
    assert "现在让我" not in json.dumps(converted, ensure_ascii=False)
    assert "<|tool_call" not in json.dumps(converted, ensure_ascii=False)


def _stream_payloads(events):
    payloads = []
    for event in events:
        for line in event.splitlines():
            if line.startswith("data: "):
                payloads.append(json.loads(line[6:]))
    return payloads


class _FakeOpenAIStream:
    def __init__(self, chunks):
        self.chunks = chunks

    async def aiter_lines(self):
        for chunk in self.chunks:
            yield "data: " + json.dumps(chunk, ensure_ascii=False)
        yield "data: [DONE]"


class _PausingOpenAIStream:
    def __init__(self, first_chunk, later_chunks):
        self.first_chunk = first_chunk
        self.later_chunks = later_chunks
        self.release = asyncio.Event()

    async def aiter_lines(self):
        yield "data: " + json.dumps(self.first_chunk, ensure_ascii=False)
        await self.release.wait()
        for chunk in self.later_chunks:
            yield "data: " + json.dumps(chunk, ensure_ascii=False)
        yield "data: [DONE]"


def test_streaming_kimi_embedded_tool_call_is_not_emitted_as_text():
    args = {"human_description": "run code", "code": "print('ok')"}
    chunks = [
        {"choices": [{"delta": {"content": "现在让我用networkx构建网络、计算拓扑参数。"}}]},
        {"choices": [{"delta": {"content": "<|tool_calls_section"}}]},
        {"choices": [{"delta": {"content": "_begin|><|tool_call_begin|>functions.python:47<|tool_call_argument_begin|>"}}]},
        {"choices": [{"delta": {"content": json.dumps(args, ensure_ascii=False) + "<|tool_call_end|><|tool_calls_section_end|>"}}]},
        {"choices": [{"delta": {}, "finish_reason": "stop"}], "usage": {"completion_tokens": 30}},
    ]

    async def collect():
        return [
            event
            async for event in proxy.translate_stream(
                _FakeOpenAIStream(chunks),
                "claude-sonnet-4-5",
                "msg_stream",
                {"python": "python", "functions.python": "python"},
            )
        ]

    events = asyncio.run(collect())
    joined = "".join(events)
    payloads = _stream_payloads(events)

    assert "<|tool_call" not in joined
    assert "现在让我" not in joined
    assert any(p.get("delta", {}).get("stop_reason") == "tool_use" for p in payloads)
    tool_starts = [
        p for p in payloads
        if p.get("type") == "content_block_start"
        and p.get("content_block", {}).get("type") == "tool_use"
    ]
    assert tool_starts
    assert tool_starts[0]["content_block"]["name"] == "python"
    assert any("print('ok')" in p.get("delta", {}).get("partial_json", "") for p in payloads)


def test_streaming_standard_tool_call_uses_zero_based_index_without_text():
    chunks = [
        {
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_123",
                        "function": {"name": "python", "arguments": "{\"code\":\"print(1)\"}"},
                    }]
                }
            }]
        },
        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
    ]

    async def collect():
        return [
            event
            async for event in proxy.translate_stream(
                _FakeOpenAIStream(chunks),
                "claude-sonnet-4-5",
                "msg_tool",
                {"python": "python"},
            )
        ]

    payloads = _stream_payloads(asyncio.run(collect()))
    starts = [p for p in payloads if p.get("type") == "content_block_start"]

    assert starts[0]["index"] == 0
    assert starts[0]["content_block"]["type"] == "tool_use"
    assert starts[0]["content_block"]["name"] == "python"


def test_streaming_text_block_stops_before_standard_tool_block_starts():
    chunks = [
        {"choices": [{"delta": {"content": "I will use python."}}]},
        {
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_123",
                        "function": {"name": "python", "arguments": "{\"code\":\"print(1)\"}"},
                    }]
                }
            }]
        },
        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
    ]

    async def collect():
        return [
            event
            async for event in proxy.translate_stream(
                _FakeOpenAIStream(chunks),
                "claude-sonnet-4-5",
                "msg_tool_order",
                {"python": "python"},
            )
        ]

    payloads = _stream_payloads(asyncio.run(collect()))
    text_stop_pos = next(
        i for i, p in enumerate(payloads)
        if p.get("type") == "content_block_stop" and p.get("index") == 0
    )
    tool_start_pos = next(
        i for i, p in enumerate(payloads)
        if p.get("type") == "content_block_start"
        and p.get("content_block", {}).get("type") == "tool_use"
    )

    assert text_stop_pos < tool_start_pos


def test_streaming_trace_preamble_before_tool_call_is_hidden():
    trace = (
        'The user said "继续" (continue). The session was resumed, which means my Python kernel was reset. '
        "Files on disk are intact. Let me check what files I have and continue with the GO/KEGG enrichment analysis.\n"
        "1. First check what files are available\n"
        "2. Run the GO/KEGG enrichment analysis using gseapy\n"
        "用户要求继续分析。会话已恢复，Python内核已重置但文件仍在。让我检查文件并继续GO/KEGG富集分析。"
    )
    chunks = [
        {"choices": [{"delta": {"content": trace[:120]}}]},
        {"choices": [{"delta": {"content": trace[120:]}}]},
        {
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_123",
                        "function": {"name": "python", "arguments": "{\"code\":\"print(1)\"}"},
                    }]
                }
            }]
        },
        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
    ]

    async def collect():
        return [
            event
            async for event in proxy.translate_stream(
                _FakeOpenAIStream(chunks),
                "claude-sonnet-4-5",
                "msg_trace_stream",
                {"python": "python"},
            )
        ]

    events = asyncio.run(collect())
    joined = "".join(events)
    payloads = _stream_payloads(events)
    starts = [p for p in payloads if p.get("type") == "content_block_start"]

    assert "The user said" not in joined
    assert "用户要求继续分析" not in joined
    assert starts[0]["content_block"]["type"] == "tool_use"


def test_streaming_normal_answer_with_tools_available_is_delivered_on_finish():
    chunks = [
        {"choices": [{"delta": {"content": "GO enrichment finished."}}]},
        {"choices": [{"delta": {}, "finish_reason": "stop"}]},
    ]

    async def collect():
        return [
            event
            async for event in proxy.translate_stream(
                _FakeOpenAIStream(chunks),
                "claude-sonnet-4-5",
                "msg_normal_stream",
                {"python": "python"},
            )
        ]

    joined = "".join(asyncio.run(collect()))

    assert "GO enrichment finished." in joined


def test_streaming_normal_text_with_tools_available_flushes_before_finish():
    first_chunk = {
        "choices": [{
            "delta": {
                "content": (
                    "GO enrichment finished successfully. The top biological processes "
                    "are inflammatory response, apoptosis, and oxidative stress regulation."
                )
            }
        }]
    }
    later_chunks = [{"choices": [{"delta": {}, "finish_reason": "stop"}]}]

    async def collect_prefix():
        stream = _PausingOpenAIStream(first_chunk, later_chunks)
        agen = proxy.translate_stream(
            stream,
            "claude-sonnet-4-5",
            "msg_no_stall",
            {"python": "python"},
        )
        first = await asyncio.wait_for(agen.__anext__(), timeout=1)
        second = await asyncio.wait_for(agen.__anext__(), timeout=1)
        stream.release.set()
        rest = []
        async for event in agen:
            rest.append(event)
        return [first, second, *rest]

    events = asyncio.run(collect_prefix())
    payloads = _stream_payloads(events[:2])

    assert payloads[0]["type"] == "message_start"
    assert payloads[1]["type"] == "content_block_start"


def test_streaming_heartbeat_emits_ping_after_message_start_idle():
    async def idle_events():
        yield proxy.sse_event("message_start", {"type": "message_start"})
        await asyncio.Event().wait()

    async def collect():
        agen = proxy.stream_events_with_heartbeat(idle_events(), interval=0.01)
        first = await asyncio.wait_for(agen.__anext__(), timeout=1)
        second = await asyncio.wait_for(agen.__anext__(), timeout=1)
        await agen.aclose()
        return [first, second]

    payloads = _stream_payloads(asyncio.run(collect()))

    assert payloads[0]["type"] == "message_start"
    assert payloads[1]["type"] == "ping"


def test_invalid_json_returns_400_without_exception():
    client = TestClient(proxy.app)
    response = client.post("/v1/messages", data="", headers={"Content-Type": "application/json"})

    assert response.status_code == 400
    assert response.json()["error"]["type"] == "invalid_request_error"


def test_oauth_profile_mock_matches_claude_science_shape():
    client = TestClient(proxy.app)
    response = client.get("/api/oauth/profile")

    assert response.status_code == 200
    data = response.json()
    assert data["account"]["uuid"] == proxy.FAKE_ACCOUNT_UUID
    assert data["account"]["email_address"] == "byok@localhost"
    assert data["organization"]["uuid"] == proxy.FAKE_ORG_UUID
    assert data["organization"]["organization_type"] == "claude_max"
    assert isinstance(data["enabled_plugins"], list)


def test_oauth_token_mock_uses_claude_ai_provider_and_scopes():
    client = TestClient(proxy.app)
    response = client.post("/api/oauth/token")

    assert response.status_code == 200
    data = response.json()
    assert data["provider"] == "claude_ai"
    for scope in ["user:inference", "user:profile", "user:mcp_servers", "user:plugins"]:
        assert scope in data["scope"].split()
