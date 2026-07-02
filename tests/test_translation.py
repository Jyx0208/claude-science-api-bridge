import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("proxy", ROOT / "proxy.py")
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)


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

