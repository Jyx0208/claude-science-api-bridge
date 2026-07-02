import asyncio
import importlib.util
import json
from contextlib import contextmanager
from pathlib import Path


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
    assert converted["content"][0] == {"type": "text", "text": "现在让我用networkx构建网络。"}
    tool_block = converted["content"][1]
    assert tool_block["type"] == "tool_use"
    assert tool_block["name"] == "python"
    assert tool_block["input"]["human_description"] == args["human_description"]
    assert "networkx" in tool_block["input"]["code"]
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
