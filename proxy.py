#!/usr/bin/env python3
"""
Local proxy that lets Claude Science use DeepSeek and ChatGPT APIs.

Features:
  - Anthropic ↔ OpenAI format translation (streaming + non-streaming)
  - Model-based routing to DeepSeek / OpenAI
  - Fake OAuth token generation
  - Web management dashboard at http://127.0.0.1:9876/dashboard
  - Persistent config via ~/.claude-science/proxy/config.json
  - Request logging and health monitoring

Quick start:
  ./start.sh
  Then open http://127.0.0.1:9876/dashboard
"""

from __future__ import annotations

import json
import os
import re
import base64
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
APP_DIR = Path(__file__).resolve().parent
PROXY_DIR = Path(os.environ.get("CLAUDE_SCIENCE_PROXY_DIR", str(APP_DIR))).expanduser()
CONFIG_FILE = PROXY_DIR / "config.json"
STATIC_DIR = PROXY_DIR / "static"
TOKEN_DIR = Path.home() / ".claude-science" / ".oauth-tokens"
ENC_KEY_FILE = Path.home() / ".claude-science" / "encryption.key"


# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------
class Config:
    """Persistent config backed by config.json."""

    DEFAULTS = {
        "deepseek_api_key": "",
        "openai_api_key": "",
        "custom_api_key": "",
        "deepseek_base_url": "https://api.deepseek.com",
        "openai_base_url": "https://api.openai.com",
        "custom_base_url": "",
        "default_backend": "deepseek",
        "force_model": "",
        "deepseek_model_map": {},
        "openai_model_map": {},
        "custom_model_map": {},
        "deepseek_model_pattern": r"deepseek|deep-seek",
        "openai_model_pattern": r"^(gpt-|o1|o3|o4|chatgpt)",
        "custom_model_pattern": "",
        "reasoning_content_policy": "fallback",
        "inline_image_policy": "auto",
        "proxy_host": "127.0.0.1",
        "proxy_port": 9876,
    }

    ENV_KEYS = {
        "deepseek_api_key": "DEEPSEEK_API_KEY",
        "openai_api_key": "OPENAI_API_KEY",
        "custom_api_key": "CUSTOM_API_KEY",
        "deepseek_base_url": "DEEPSEEK_BASE_URL",
        "openai_base_url": "OPENAI_BASE_URL",
        "custom_base_url": "CUSTOM_BASE_URL",
        "default_backend": "DEFAULT_BACKEND",
        "force_model": "FORCE_MODEL",
        "deepseek_model_map": "DEEPSEEK_MODEL_MAP",
        "openai_model_map": "OPENAI_MODEL_MAP",
        "custom_model_map": "CUSTOM_MODEL_MAP",
        "deepseek_model_pattern": "DEEPSEEK_MODEL_PATTERN",
        "openai_model_pattern": "OPENAI_MODEL_PATTERN",
        "custom_model_pattern": "CUSTOM_MODEL_PATTERN",
        "reasoning_content_policy": "REASONING_CONTENT_POLICY",
        "inline_image_policy": "INLINE_IMAGE_POLICY",
        "proxy_host": "PROXY_HOST",
        "proxy_port": "PROXY_PORT",
    }
    JSON_KEYS = {"deepseek_model_map", "openai_model_map", "custom_model_map"}

    def __init__(self):
        self._data = dict(self.DEFAULTS)
        self._load()
        self._load_env()

    def _load(self):
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE) as f:
                    stored = json.load(f)
                self._data.update(stored)
            except Exception:
                pass

    def _load_env(self):
        for key, env_key in self.ENV_KEYS.items():
            value = os.environ.get(env_key)
            if value in (None, ""):
                continue
            try:
                if key in self.JSON_KEYS:
                    value = json.loads(value)
                elif key == "proxy_port":
                    value = int(value)
            except Exception:
                continue
            self._data[key] = value

    def save(self):
        PROXY_DIR.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump(self._data, f, indent=2)
        os.chmod(CONFIG_FILE, 0o600)

    def get(self, key: str, default=None):
        return self._data.get(key, default)

    def update(self, d: dict):
        self._data.update(d)
        self.save()

    def public_dict(self) -> dict:
        """Return config with API keys masked."""
        d = dict(self._data)
        for k in ("deepseek_api_key", "openai_api_key", "custom_api_key"):
            val = d.get(k, "")
            if val and len(val) > 8:
                d[k] = val[:4] + "•" * (len(val) - 8) + val[-4:]
        return d

    @property
    def deepseek_api_key(self) -> str: return self._data["deepseek_api_key"]
    @property
    def openai_api_key(self) -> str: return self._data["openai_api_key"]
    @property
    def custom_api_key(self) -> str: return self._data["custom_api_key"]
    @property
    def deepseek_base_url(self) -> str: return self._data["deepseek_base_url"]
    @property
    def openai_base_url(self) -> str: return self._data["openai_base_url"]
    @property
    def custom_base_url(self) -> str: return self._data["custom_base_url"]
    @property
    def default_backend(self) -> str: return self._data["default_backend"]
    @property
    def force_model(self) -> str: return self._data["force_model"]
    @property
    def deepseek_model_map(self) -> dict: return self._data["deepseek_model_map"]
    @property
    def openai_model_map(self) -> dict: return self._data["openai_model_map"]
    @property
    def custom_model_map(self) -> dict: return self._data["custom_model_map"]
    @property
    def deepseek_model_pattern(self) -> str: return self._data["deepseek_model_pattern"]
    @property
    def openai_model_pattern(self) -> str: return self._data["openai_model_pattern"]
    @property
    def custom_model_pattern(self) -> str: return self._data["custom_model_pattern"]
    @property
    def reasoning_content_policy(self) -> str: return self._data["reasoning_content_policy"]
    @property
    def inline_image_policy(self) -> str: return self._data["inline_image_policy"]
    @property
    def proxy_host(self) -> str: return self._data["proxy_host"]
    @property
    def proxy_port(self) -> int: return self._data["proxy_port"]

    def resolve_backend(self, model: str) -> dict:
        """Determine which backend to use and what model name to send."""
        backend = self.default_backend
        try:
            ds_pat = re.compile(self.deepseek_model_pattern, re.IGNORECASE)
            oa_pat = re.compile(self.openai_model_pattern, re.IGNORECASE)
            custom_pat = re.compile(self.custom_model_pattern, re.IGNORECASE) if self.custom_model_pattern else None
        except re.error:
            ds_pat = re.compile(r"deepseek|deep-seek", re.IGNORECASE)
            oa_pat = re.compile(r"^(gpt-|o1|o3|o4|chatgpt)", re.IGNORECASE)
            custom_pat = None

        if ds_pat.search(model):
            backend = "deepseek"
        elif oa_pat.search(model):
            backend = "openai"
        elif custom_pat and custom_pat.search(model):
            backend = "custom"

        if backend == "deepseek":
            api_key = self.deepseek_api_key
            base_url = normalize_openai_base_url(self.deepseek_base_url)
            mapped_model = self.force_model or self.deepseek_model_map.get(model, model)
        elif backend == "openai":
            api_key = self.openai_api_key
            base_url = normalize_openai_base_url(self.openai_base_url)
            mapped_model = self.force_model or self.openai_model_map.get(model, model)
        elif backend == "custom":
            api_key = self.custom_api_key
            base_url = normalize_openai_base_url(self.custom_base_url)
            mapped_model = self.force_model or self.custom_model_map.get(model, model)
        else:
            raise ValueError(f"Unsupported backend '{backend}'. Use deepseek, openai, or custom.")

        if not api_key:
            raise ValueError(
                f"No API key configured for backend '{backend}'. "
                f"Set it in the dashboard: http://{self.proxy_host}:{self.proxy_port}/dashboard"
            )

        return {
            "backend": backend,
            "model": mapped_model,
            "api_key": api_key,
            "base_url": base_url,
        }


# Global config
config = Config()


def normalize_openai_base_url(base_url: str) -> str:
    """Return the OpenAI-compatible /v1 base URL without duplicating /v1."""
    cleaned = (base_url or "").rstrip("/")
    if not cleaned:
        return ""
    return cleaned if cleaned.endswith("/v1") else cleaned + "/v1"

# ---------------------------------------------------------------------------
# Request log (in-memory ring buffer)
# ---------------------------------------------------------------------------
MAX_LOG_ENTRIES = 200
request_log: list[dict] = []


def log_request(backend: str, model: str, stream: bool, status: str):
    entry = {
        "time": datetime.now().strftime("%H:%M:%S"),
        "backend": backend,
        "model": model,
        "stream": stream,
        "status": status,
    }
    request_log.append(entry)
    if len(request_log) > MAX_LOG_ENTRIES:
        request_log.pop(0)


def log_local_event(request: Request, status_code: int):
    path = request.url.path
    if path.startswith("/static") or path in {"/dashboard", "/favicon.ico"}:
        return
    host = request.headers.get("host", "")
    entry = {
        "time": datetime.now().strftime("%H:%M:%S"),
        "backend": "local",
        "model": f"{request.method} {host}{path}",
        "stream": False,
        "status": str(status_code),
    }
    request_log.append(entry)
    if len(request_log) > MAX_LOG_ENTRIES:
        request_log.pop(0)
    print(f"[proxy] <- {request.method} host={host} path={path} status={status_code}")


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(title="Claude Science BYOK Proxy", version="2.0.0")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Path normalization middleware
class NormalizePathMiddleware(BaseHTTPMiddleware):
    PASSTHROUGH = {"/health", "/dashboard", "/docs", "/openapi.json", "/favicon.ico"}

    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        # Skip static files and dashboard
        if path.startswith("/static") or path in self.PASSTHROUGH or path.startswith("/api"):
            return await call_next(request)

        while "/v1/v1/" in path:
            path = path.replace("/v1/v1/", "/v1/", 1)
        if not path.startswith("/v1/") and path not in self.PASSTHROUGH and not path.startswith("/docs"):
            path = "/v1" + path

        request.scope["path"] = path
        request.scope["raw_path"] = path.encode()
        return await call_next(request)


app.add_middleware(NormalizePathMiddleware)


@app.middleware("http")
async def access_log_middleware(request: Request, call_next):
    response = await call_next(request)
    log_local_event(request, response.status_code)
    return response

# Static files for dashboard
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

# Shared HTTP client
_client: Optional[httpx.AsyncClient] = None


def get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            timeout=httpx.Timeout(120.0, connect=10.0),
            limits=httpx.Limits(max_keepalive_connections=20),
            trust_env=False,
        )
    return _client


# ---------------------------------------------------------------------------
# Request/Response translation: Anthropic <-> OpenAI
# ---------------------------------------------------------------------------

TOOL_NAME_RE = re.compile(r"[^A-Za-z0-9_-]+")
DATA_IMAGE_RE = re.compile(r"^data:(image/[^;,]+);base64,(.*)$", re.DOTALL)
JSON_SCHEMA_TYPES = {"string", "number", "integer", "boolean", "object", "array"}
SCHEMA_COMBINATORS = ("anyOf", "oneOf", "allOf")


def normalize_tool_name(name, fallback: str) -> str:
    """OpenAI-compatible function names are alphanumeric plus _ and -."""
    cleaned = TOOL_NAME_RE.sub("_", str(name or fallback)).strip("_")
    return (cleaned or fallback)[:64]


def _pick_schema_type(value):
    if isinstance(value, str) and value in JSON_SCHEMA_TYPES:
        return value
    if isinstance(value, list):
        candidates = [v for v in value if isinstance(v, str) and v in JSON_SCHEMA_TYPES]
        if "object" in candidates:
            return "object"
        if "array" in candidates:
            return "array"
        if candidates:
            return candidates[0]
    return None


def _infer_schema_type(schema: dict):
    if "properties" in schema:
        return "object"
    if "items" in schema:
        return "array"
    enum_values = schema.get("enum")
    if isinstance(enum_values, list):
        for value in enum_values:
            if value is None:
                continue
            if isinstance(value, bool):
                return "boolean"
            if isinstance(value, int):
                return "integer"
            if isinstance(value, float):
                return "number"
            if isinstance(value, str):
                return "string"
    return None


def sanitize_tool_schema(schema, *, force_object: bool = False) -> dict:
    """Normalize Claude tool schemas for OpenAI-compatible providers.

    Claude Science can send tool schemas with a missing or null root type.
    DeepSeek rejects those for function parameters, so the root must always be
    an object schema. Nested schemas are kept permissive but never keep
    `type: null`.
    """
    if not isinstance(schema, dict):
        return {"type": "object", "properties": {}} if force_object else {}

    cleaned = {}
    schema_type = _pick_schema_type(schema.get("type")) or _infer_schema_type(schema)
    if force_object:
        schema_type = "object"
    if schema_type:
        cleaned["type"] = schema_type

    for key, value in schema.items():
        if key == "type" or value is None:
            continue
        if key == "properties":
            if isinstance(value, dict):
                cleaned["properties"] = {
                    str(prop_name): sanitize_tool_schema(prop_schema)
                    for prop_name, prop_schema in value.items()
                }
            continue
        if key == "items":
            if isinstance(value, dict):
                cleaned["items"] = sanitize_tool_schema(value)
            elif isinstance(value, list):
                cleaned["items"] = [sanitize_tool_schema(item) for item in value if isinstance(item, dict)]
            continue
        if key in SCHEMA_COMBINATORS:
            if isinstance(value, list):
                variants = [sanitize_tool_schema(item) for item in value if isinstance(item, dict)]
                if variants:
                    cleaned[key] = variants
            continue
        if key == "required":
            if isinstance(value, list):
                required = [item for item in value if isinstance(item, str)]
                if required:
                    cleaned["required"] = required
            continue
        if key == "enum":
            if isinstance(value, list):
                enum_values = [item for item in value if item is not None]
                if enum_values:
                    cleaned["enum"] = enum_values
            continue
        if key == "additionalProperties":
            if isinstance(value, bool):
                cleaned[key] = value
            elif isinstance(value, dict):
                cleaned[key] = sanitize_tool_schema(value)
            continue
        if key in {
            "description", "title", "format", "pattern", "minimum", "maximum",
            "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength",
            "minItems", "maxItems", "default", "const",
        }:
            cleaned[key] = value

    if force_object:
        cleaned["type"] = "object"
        if not isinstance(cleaned.get("properties"), dict):
            cleaned["properties"] = {}
    return cleaned


def _is_inline_image_url(url: str) -> bool:
    return isinstance(url, str) and url.startswith("data:")


def _siliconflow_needs_jpeg_data_url(backend_name: str, backend_base_url: str) -> bool:
    return backend_name == "custom" and "siliconflow" in (backend_base_url or "").lower()


def _convert_inline_image_to_jpeg_url(url: str, backend_name: str, backend_base_url: str) -> str:
    """Convert inline data images to JPEG for providers that reject PNG data URLs."""
    if not (_is_inline_image_url(url) and _siliconflow_needs_jpeg_data_url(backend_name, backend_base_url)):
        return url

    match = DATA_IMAGE_RE.match(url)
    if not match:
        return url

    mime_type = match.group(1).lower()
    if mime_type in {"image/jpeg", "image/jpg"}:
        return url
    if not shutil.which("sips"):
        return url

    ext = {
        "image/png": "png",
        "image/webp": "webp",
        "image/gif": "gif",
        "image/heic": "heic",
        "image/heif": "heif",
    }.get(mime_type, "img")

    try:
        raw = base64.b64decode(match.group(2), validate=False)
        with tempfile.TemporaryDirectory(prefix="claude-science-img-") as td:
            src_path = Path(td) / f"source.{ext}"
            dst_path = Path(td) / "converted.jpg"
            src_path.write_bytes(raw)
            subprocess.run(
                ["sips", "-s", "format", "jpeg", str(src_path), "--out", str(dst_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
                timeout=15,
            )
            encoded = base64.b64encode(dst_path.read_bytes()).decode("ascii")
            return f"data:image/jpeg;base64,{encoded}"
    except Exception:
        return url


def _openai_image_url_from_anthropic(block: dict) -> Optional[str]:
    if "image_url" in block:
        image_url = block["image_url"]
        if isinstance(image_url, dict):
            return image_url.get("url")
        if isinstance(image_url, str):
            return image_url
    if "source" in block:
        src = block["source"]
        if isinstance(src, dict):
            mt = src.get("media_type", "image/png")
            d = src.get("data", "")
            if d:
                return f"data:{mt};base64,{d}"
    return None


def _image_policy_for_backend(backend_name: str, backend_base_url: str) -> str:
    policy = (config.inline_image_policy or "auto").lower()
    if policy in {"preserve", "omit", "omit_inline"}:
        return policy
    if backend_name == "deepseek":
        return "omit"
    return "preserve"


def anthropic_to_openai(
    anthropic_body: dict,
    backend_model: str,
    backend_name: str = "",
    backend_base_url: str = "",
) -> dict:
    """Convert Anthropic Messages API request → OpenAI Chat Completions format."""
    openai_messages = []
    backend_name = backend_name.lower()
    image_policy = _image_policy_for_backend(backend_name, backend_base_url)

    # System prompt
    system = anthropic_body.get("system")
    if system:
        if isinstance(system, str):
            openai_messages.append({"role": "system", "content": system})
        elif isinstance(system, list):
            parts = [b["text"] for b in system if isinstance(b, dict) and b.get("type") == "text"]
            if parts:
                openai_messages.append({"role": "system", "content": "\n".join(parts)})

    # Messages
    for msg in anthropic_body.get("messages", []):
        role = msg.get("role", "user")
        content = msg.get("content")

        if role == "user":
            tool_messages = []
            if isinstance(content, str):
                openai_content = content
            elif isinstance(content, list):
                text_parts, image_parts, omitted_images = [], [], 0
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    t = block.get("type", "")
                    if t == "tool_result":
                        tool_content = block.get("content", "")
                        if isinstance(tool_content, list):
                            result_parts = []
                            for item in tool_content:
                                if isinstance(item, dict) and item.get("type") == "text":
                                    result_parts.append(item.get("text", ""))
                                elif isinstance(item, str):
                                    result_parts.append(item)
                                else:
                                    result_parts.append(json.dumps(item, ensure_ascii=False))
                            tool_content = "\n".join(part for part in result_parts if part)
                        elif not isinstance(tool_content, str):
                            tool_content = json.dumps(tool_content, ensure_ascii=False)
                        tool_messages.append({
                            "role": "tool",
                            "tool_call_id": block.get("tool_use_id", ""),
                            "content": tool_content,
                        })
                    elif t == "text":
                        text_parts.append(block["text"])
                    elif t in ("image", "image_url"):
                        url = _openai_image_url_from_anthropic(block)
                        if not url:
                            omitted_images += 1
                            continue
                        if image_policy == "omit" or (image_policy == "omit_inline" and _is_inline_image_url(url)):
                            omitted_images += 1
                        else:
                            url = _convert_inline_image_to_jpeg_url(url, backend_name, backend_base_url)
                            image_parts.append({"type": "image_url", "image_url": {"url": url}})
                if image_parts:
                    openai_parts = list(image_parts)
                    if text_parts:
                        openai_parts.insert(0, {"type": "text", "text": " ".join(text_parts)})
                    if omitted_images:
                        openai_parts.append({
                            "type": "text",
                            "text": f"[{omitted_images} inline image attachment(s) omitted for backend compatibility.]",
                        })
                    openai_content = openai_parts
                elif omitted_images:
                    image_note = f"[{omitted_images} inline image attachment(s) omitted for backend compatibility.]"
                    openai_content = " ".join([*text_parts, image_note]).strip()
                else:
                    openai_content = " ".join(text_parts)
            else:
                openai_content = str(content)

            openai_messages.extend(tool_messages)
            if openai_content:
                openai_messages.append({"role": "user", "content": openai_content})

        elif role == "assistant":
            if isinstance(content, str):
                openai_messages.append({"role": "assistant", "content": content})
            elif isinstance(content, list):
                text_parts, tool_calls = [], []
                for block in content:
                    if block.get("type") == "text":
                        text_parts.append(block["text"])
                    elif block.get("type") == "tool_use":
                        tool_calls.append({
                            "id": block.get("id", ""),
                            "type": "function",
                            "function": {
                                "name": block.get("name", ""),
                                "arguments": json.dumps(block.get("input", {})),
                            },
                        })
                am = {"role": "assistant"}
                am["content"] = " ".join(text_parts) if text_parts else None
                if tool_calls:
                    am["tool_calls"] = tool_calls
                openai_messages.append(am)
            else:
                openai_messages.append({"role": "assistant", "content": str(content)})

    openai_body = {"model": backend_model, "messages": openai_messages}

    max_tokens = anthropic_body.get("max_tokens", 4096)
    openai_body["max_tokens"] = max_tokens

    if "temperature" in anthropic_body:
        openai_body["temperature"] = anthropic_body["temperature"]
    if "top_p" in anthropic_body:
        openai_body["top_p"] = anthropic_body["top_p"]

    stop_seq = anthropic_body.get("stop_sequences")
    if stop_seq:
        if isinstance(stop_seq, list) and len(stop_seq) == 1:
            openai_body["stop"] = stop_seq[0]
        elif isinstance(stop_seq, list):
            openai_body["stop"] = stop_seq

    openai_body["stream"] = anthropic_body.get("stream", False)

    # Tools
    tools = anthropic_body.get("tools")
    if tools:
        openai_tools = []
        tool_name_map = {}
        for idx, tool in enumerate(tools):
            if isinstance(tool, dict):
                original_name = str(tool.get("name", "") or f"tool_{idx}")
                safe_name = normalize_tool_name(original_name, f"tool_{idx}")
                tool_name_map[original_name] = safe_name
                parameters = sanitize_tool_schema(tool.get("input_schema", {}), force_object=True)
                openai_tools.append({
                    "type": "function",
                    "function": {
                        "name": safe_name,
                        "description": tool.get("description", ""),
                        "parameters": parameters,
                    },
                })
        if openai_tools:
            openai_body["tools"] = openai_tools
            tool_choice = anthropic_body.get("tool_choice")
            if tool_choice and backend_name != "deepseek":
                if isinstance(tool_choice, dict) and tool_choice.get("type") == "tool":
                    choice_name = str(tool_choice.get("name", ""))
                    openai_body["tool_choice"] = {
                        "type": "function",
                        "function": {"name": tool_name_map.get(choice_name, normalize_tool_name(choice_name, "tool_0"))},
                    }
                elif tool_choice == "any":
                    openai_body["tool_choice"] = "required"
                elif tool_choice == "auto":
                    openai_body["tool_choice"] = "auto"

    return openai_body


def openai_to_anthropic_response(openai_resp: dict, original_model: str, request_id: str) -> dict:
    choice = openai_resp.get("choices", [{}])[0]
    message = choice.get("message", {})
    content_blocks = []

    normal_content = message.get("content", "") or ""
    reasoning_content = message.get("reasoning_content", "") or ""
    policy = config.reasoning_content_policy
    if policy == "always" and reasoning_content:
        text_content = reasoning_content + (f"\n\n{normal_content}" if normal_content else "")
    elif policy == "fallback":
        text_content = normal_content or reasoning_content
    else:
        text_content = normal_content
    if text_content:
        content_blocks.append({"type": "text", "text": text_content})

    for tc in message.get("tool_calls") or []:
        func = tc.get("function", {})
        try:
            arguments = json.loads(func.get("arguments", "{}"))
        except json.JSONDecodeError:
            arguments = {"_raw": func.get("arguments", "{}")}
        content_blocks.append({
            "type": "tool_use",
            "id": tc.get("id", f"toolu_{uuid.uuid4().hex[:12]}"),
            "name": func.get("name", ""),
            "input": arguments,
        })

    usage = openai_resp.get("usage", {})
    return {
        "id": request_id,
        "type": "message",
        "role": "assistant",
        "content": content_blocks,
        "model": original_model,
        "stop_reason": _map_finish_reason(choice.get("finish_reason", "stop")),
        "stop_sequence": None,
        "usage": {"input_tokens": usage.get("prompt_tokens", 0), "output_tokens": usage.get("completion_tokens", 0)},
    }


def _map_finish_reason(r: str) -> str:
    m = {"stop": "end_turn", "length": "max_tokens", "tool_calls": "tool_use", "function_call": "tool_use", "content_filter": "end_turn"}
    return m.get(r, "end_turn")


# ---------------------------------------------------------------------------
# Streaming translation
# ---------------------------------------------------------------------------

async def translate_stream(openai_stream, original_model: str, request_id: str):
    tool_calls_map: dict[int, dict] = {}
    finish_reason = None
    output_tokens = 0
    message_started = False
    content_block_started = False

    def ev(t: str, d: dict) -> str:
        return f"event: {t}\ndata: {json.dumps(d)}\n\n"

    async for line in openai_stream.aiter_lines():
        if not line or not line.startswith("data: "):
            continue
        payload = line[6:]
        if payload.strip() == "[DONE]":
            break
        try:
            chunk = json.loads(payload)
        except json.JSONDecodeError:
            continue

        usage = chunk.get("usage") or {}
        if usage:
            output_tokens = usage.get("completion_tokens", output_tokens)

        choices = chunk.get("choices", [])
        if not choices:
            continue

        choice = choices[0]
        delta = choice.get("delta", {})
        finish_reason = choice.get("finish_reason") or finish_reason

        if not message_started:
            message_started = True
            yield ev("message_start", {
                "type": "message_start",
                "message": {
                    "id": request_id, "type": "message", "role": "assistant",
                    "content": [], "model": original_model,
                    "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                },
            })

        text_delta = delta.get("content", "") or ""
        if not text_delta and config.reasoning_content_policy != "never":
            text_delta = delta.get("reasoning_content", "") or ""
        if text_delta:
            if not content_block_started:
                content_block_started = True
                yield ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            yield ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text_delta}})

        for tc_delta in delta.get("tool_calls") or []:
            idx = tc_delta.get("index", 0)
            func_delta = tc_delta.get("function", {})
            if idx not in tool_calls_map:
                tool_calls_map[idx] = {"id": tc_delta.get("id", ""), "name": func_delta.get("name", ""), "arguments": ""}
                yield ev("content_block_start", {
                    "type": "content_block_start", "index": idx + 1,
                    "content_block": {"type": "tool_use", "id": tool_calls_map[idx]["id"], "name": tool_calls_map[idx]["name"], "input": {}},
                })
            if func_delta.get("name"):
                tool_calls_map[idx]["name"] = func_delta["name"]
            if tc_delta.get("id"):
                tool_calls_map[idx]["id"] = tc_delta["id"]
            if func_delta.get("arguments"):
                tool_calls_map[idx]["arguments"] += func_delta["arguments"]
                yield ev("content_block_delta", {"type": "content_block_delta", "index": idx + 1, "delta": {"type": "input_json_delta", "partial_json": func_delta["arguments"]}})

        if finish_reason:
            if content_block_started:
                yield ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            for idx in sorted(tool_calls_map.keys()):
                yield ev("content_block_delta", {"type": "content_block_delta", "index": idx + 1, "delta": {"type": "input_json_delta", "partial_json": ""}})
                yield ev("content_block_stop", {"type": "content_block_stop", "index": idx + 1})
            yield ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": _map_finish_reason(finish_reason), "stop_sequence": None}, "usage": {"output_tokens": output_tokens}})
            yield ev("message_stop", {"type": "message_stop"})
            break

    if message_started and not finish_reason:
        if content_block_started:
            yield ev("content_block_stop", {"type": "content_block_stop", "index": 0})
        yield ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": output_tokens}})
        yield ev("message_stop", {"type": "message_stop"})


# ---------------------------------------------------------------------------
# Anthropic API routes
# ---------------------------------------------------------------------------

@app.post("/v1/messages")
async def messages_api(request: Request):
    body = await request.json()
    original_model = body.get("model", "claude-sonnet-4-5")

    try:
        backend = config.resolve_backend(original_model)
    except ValueError as e:
        return JSONResponse({"type": "error", "error": {"type": "api_error", "message": str(e)}}, status_code=400)

    stream = body.get("stream", False)
    request_id = f"msg_{uuid.uuid4().hex[:16]}"
    openai_body = anthropic_to_openai(body, backend["model"], backend["backend"], backend["base_url"])

    print(f"[proxy] → {backend['backend']} | model={backend['model']} | "
          f"stream={stream} | original_model={original_model}")

    headers = {"Authorization": f"Bearer {backend['api_key']}", "Content-Type": "application/json"}
    client = get_client()
    url = f"{backend['base_url']}/chat/completions"

    if stream:
        async def stream_gen():
            try:
                async with client.stream("POST", url, json=openai_body, headers=headers) as backend_resp:
                    if backend_resp.status_code != 200:
                        try:
                            error_text = (await backend_resp.aread()).decode("utf-8", errors="replace")[:500]
                        except Exception:
                            error_text = "(unreadable response)"
                        print(f"[proxy] backend error {backend_resp.status_code}: {error_text}", flush=True)
                        log_request(backend["backend"], backend["model"], True, f"error {backend_resp.status_code}")
                        err_msg = f"Backend error {backend_resp.status_code}: {error_text}"
                        safe_msg = err_msg.encode("ascii", errors="replace").decode("ascii")
                        yield f"event: error\ndata: {json.dumps({'type':'error','error':{'type':'api_error','message':safe_msg}})}\n\n"
                        return
                    log_request(backend["backend"], backend["model"], True, "success")
                    async for event in translate_stream(backend_resp, original_model, request_id):
                        yield event
            except Exception as e:
                log_request(backend["backend"], backend["model"], True, "error")
                yield f"event: error\ndata: {json.dumps({'type':'error','error':{'type':'api_error','message':str(e)}})}\n\n"

        return StreamingResponse(stream_gen(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"})
    else:
        try:
            resp = await client.post(url, json=openai_body, headers=headers)
            if resp.status_code != 200:
                err_text = resp.text[:500] if resp.text else "(empty)"
                print(f"[proxy] backend error {resp.status_code}: {err_text}", flush=True)
                log_request(backend["backend"], backend["model"], False, f"error {resp.status_code}")
                safe_msg = f"Backend returned {resp.status_code}: {err_text}".encode("ascii", errors="replace").decode("ascii")
                return JSONResponse({"type": "error", "error": {"type": "api_error", "message": safe_msg}}, status_code=resp.status_code)
            log_request(backend["backend"], backend["model"], False, "success")
            return JSONResponse(openai_to_anthropic_response(resp.json(), original_model, request_id))
        except Exception as e:
            log_request(backend["backend"], backend["model"], False, "error")
            safe_msg = str(e).encode("ascii", errors="replace").decode("ascii")
            return JSONResponse({"type": "error", "error": {"type": "api_error", "message": safe_msg}}, status_code=502)


@app.post("/v1/messages/count_tokens")
async def count_tokens(request: Request):
    body = await request.json()
    total_chars = 0
    for msg in body.get("messages", []):
        content = msg.get("content", "")
        if isinstance(content, str):
            total_chars += len(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    total_chars += len(json.dumps(block))
    system = body.get("system", "")
    if isinstance(system, str):
        total_chars += len(system)
    elif isinstance(system, list):
        total_chars += len(json.dumps(system))
    return JSONResponse({"input_tokens": max(1, total_chars // 4)})


# ---------------------------------------------------------------------------
# OAuth mocks
# ---------------------------------------------------------------------------

FAKE_ACCOUNT_UUID = "byok-user-000000000000000000"
FAKE_ORG_UUID = "org_byok_000000000000"
FAKE_ACCESS_TOKEN = "fake-bearer-token-for-proxy"


def fake_token_response() -> dict:
    return {
        "token_type": "bearer",
        "access_token": FAKE_ACCESS_TOKEN,
        "refresh_token": "fake-refresh-token",
        "expires_in": 999999999,
        "expires_at": "2099-12-31T23:59:59Z",
        "scope": "openid profile email",
    }


def fake_user_response() -> dict:
    return {
        "id": FAKE_ACCOUNT_UUID,
        "uuid": FAKE_ACCOUNT_UUID,
        "sub": FAKE_ACCOUNT_UUID,
        "email": "byok@localhost",
        "email_verified": True,
        "name": "BYOK User",
        "organization": fake_org_response(),
        "organization_uuid": FAKE_ORG_UUID,
        "org_uuid": FAKE_ORG_UUID,
        "subscription_type": "max",
        "rate_limit_tier": "tier_5",
        "seat_tier": "enterprise_usage_based",
        "billing_type": "api",
        "has_extra_usage_enabled": True,
    }


def fake_org_response() -> dict:
    return {
        "id": FAKE_ORG_UUID,
        "uuid": FAKE_ORG_UUID,
        "name": "BYOK Organization",
        "type": "organization",
        "status": "active",
        "default_role": "admin",
        "subscription": {"type": "max", "status": "active"},
        "rate_limit_tier": "tier_5",
        "billing_type": "api",
    }


def fake_org_list_response() -> dict:
    org = fake_org_response()
    return {
        **org,
        "data": [org],
        "organizations": [org],
        "has_more": False,
        "first_id": org["id"],
        "last_id": org["id"],
    }


@app.api_route("/v1/oauth/{path:path}", methods=["GET", "POST", "PUT", "DELETE"])
async def oauth_mock(request: Request, path: str):
    return JSONResponse(fake_token_response())


@app.get("/v1/userinfo")
@app.get("/v1/me")
@app.get("/v1/user")
@app.get("/v1/profile")
@app.get("/v1/account")
async def userinfo_mock(request: Request):
    return JSONResponse(fake_user_response())



@app.get("/v1/models")
async def list_models(request: Request):
    """Return compatible model list."""
    models = [
        {"id": "claude-sonnet-4-5", "type": "model", "display_name": "Claude Sonnet 4.5"},
        {"id": "claude-opus-4-8", "type": "model", "display_name": "Claude Opus 4.8"},
        {"id": "claude-haiku-4-5-20251001", "type": "model", "display_name": "Claude Haiku 4.5"},
        {"id": "deepseek-chat", "type": "model", "display_name": "DeepSeek Chat"},
        {"id": "deepseek-reasoner", "type": "model", "display_name": "DeepSeek Reasoner"},
        {"id": "gpt-4o", "type": "model", "display_name": "GPT-4o"},
    ]
    return JSONResponse({"data": models, "has_more": False, "first_id": models[0]["id"], "last_id": models[-1]["id"]})


# Add proper organization endpoint (not just catch-all)
@app.get("/v1/organizations")
async def orgs_mock(request: Request):
    """Mock organization list endpoint."""
    return JSONResponse(fake_org_list_response())


@app.get("/v1/organization")
@app.get("/v1/organizations/{org_id}")
async def org_mock(request: Request, org_id: str = FAKE_ORG_UUID):
    """Mock single organization endpoint."""
    return JSONResponse(fake_org_response())


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def catch_all(request: Request, path: str):
    lowered = path.lower()
    if "oauth" in lowered or "token" in lowered:
        return JSONResponse(fake_token_response())
    if "organization" in lowered or lowered.startswith("org"):
        return JSONResponse(fake_org_list_response())
    if any(k in lowered for k in ("userinfo", "profile", "account", "user", "me")):
        return JSONResponse(fake_user_response())
    return JSONResponse({"ok": True})


# ---------------------------------------------------------------------------
# Dashboard & Management API
# ---------------------------------------------------------------------------

@app.get("/dashboard")
async def dashboard():
    return FileResponse(str(STATIC_DIR / "dashboard.html"))


@app.get("/api/config")
async def api_get_config():
    return config.public_dict()


@app.post("/api/config")
async def api_update_config(request: Request):
    body = await request.json()
    allowed_keys = {
        "deepseek_api_key", "openai_api_key", "custom_api_key",
        "deepseek_base_url", "openai_base_url", "custom_base_url",
        "default_backend", "force_model",
        "deepseek_model_map", "openai_model_map", "custom_model_map",
        "deepseek_model_pattern", "openai_model_pattern", "custom_model_pattern",
        "reasoning_content_policy", "inline_image_policy",
    }
    update_data = {k: v for k, v in body.items() if k in allowed_keys}
    # Reject masked API keys (bullet character U+2022)
    for key in ("deepseek_api_key", "openai_api_key", "custom_api_key"):
        if key in update_data and "•" in update_data[key]:
            del update_data[key]  # Skip masked placeholder
    if update_data:
        config.update(update_data)
        return {"ok": True}
    return {"ok": False, "error": "No valid config keys provided"}


@app.post("/api/test-backend")
async def api_test_backend(request: Request):
    """Test connectivity to a backend provider."""
    body = await request.json()
    provider = body.get("provider", "deepseek")
    api_key = body.get("api_key", "")
    base_url = body.get("base_url", "")

    if not api_key:
        return {"ok": False, "error": "API key is required"}

    if base_url:
        url = f"{normalize_openai_base_url(base_url)}/models"
    elif provider == "deepseek":
        url = "https://api.deepseek.com/v1/models"
    elif provider == "openai":
        url = "https://api.openai.com/v1/models"
    else:
        return {"ok": False, "error": "Custom provider requires an API Base URL"}

    try:
        async with httpx.AsyncClient(timeout=10, trust_env=False) as c:
            resp = await c.get(url, headers={"Authorization": f"Bearer {api_key}"})
            if resp.status_code == 200:
                data = resp.json()
                models = [m.get("id", "") for m in data.get("data", [])[:10]]
                return {"ok": True, "models": models}
            else:
                return {"ok": False, "error": f"HTTP {resp.status_code}: {resp.text[:300]}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/setup-global-env")
async def api_setup_global_env():
    """Set ANTHROPIC_BASE_URL globally on macOS via launchctl."""
    proxy_url = f"http://{config.proxy_host}:{config.proxy_port}"
    try:
        subprocess.run(
            ["launchctl", "setenv", "ANTHROPIC_BASE_URL", proxy_url],
            capture_output=True, text=True, timeout=5,
        )
        return {"ok": True, "proxy_url": proxy_url}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/install-service")
async def api_install_service():
    """Install proxy as a macOS LaunchAgent for auto-start on login."""
    plist_name = "com.byok.claude-science-proxy.plist"
    plist_dir = Path.home() / "Library" / "LaunchAgents"
    plist_path = plist_dir / plist_name

    proxy_url = f"http://{config.proxy_host}:{config.proxy_port}"

    python_dir = str(Path(sys.executable).parent)
    plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.byok.claude-science-proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>{sys.executable}</string>
        <string>{Path(__file__).resolve()}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>{PROXY_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ANTHROPIC_BASE_URL</key>
        <string>{proxy_url}</string>
        <key>PROXY_HOST</key>
        <string>{config.proxy_host}</string>
        <key>PROXY_PORT</key>
        <string>{config.proxy_port}</string>
        <key>PATH</key>
        <string>{python_dir}:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>{Path.home() / ".claude-science" / "logs" / "proxy.log"}</string>
    <key>StandardErrorPath</key>
    <string>{Path.home() / ".claude-science" / "logs" / "proxy-error.log"}</string>
</dict>
</plist>"""

    try:
        plist_dir.mkdir(parents=True, exist_ok=True)
        with open(plist_path, "w") as f:
            f.write(plist_content)

        # Unload old, load new
        subprocess.run(["launchctl", "unload", str(plist_path)], capture_output=True)
        subprocess.run(["launchctl", "load", str(plist_path)], capture_output=True)

        # Also save a copy in the proxy dir
        copy_path = PROXY_DIR / plist_name
        with open(copy_path, "w") as f:
            f.write(plist_content)

        return {"ok": True, "plist_path": str(plist_path)}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/refresh-token")
async def api_refresh_token():
    """Re-generate the fake OAuth token."""
    try:
        result = subprocess.run(
            [sys.executable, str(PROXY_DIR / "setup-token.py")],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            return {"ok": True, "output": result.stdout.strip().split("\n")[-3:]}
        return {"ok": False, "error": result.stderr or result.stdout}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.get("/api/recent-requests")
async def api_recent_requests():
    return {"requests": list(reversed(request_log[-50:]))}


@app.delete("/api/recent-requests")
async def api_clear_requests():
    request_log.clear()
    return {"ok": True}


@app.api_route("/api/oauth/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def api_oauth_mock(request: Request, path: str):
    lowered = path.lower()
    if any(k in lowered for k in ("profile", "account", "userinfo", "user", "me")):
        return JSONResponse(fake_user_response())
    if "organization" in lowered or lowered.startswith("org"):
        return JSONResponse(fake_org_list_response())
    if "usage" in lowered:
        return JSONResponse({
            "usage": {"used": 0, "limit": 999999999, "remaining": 999999999},
            "organization": fake_org_response(),
            "organizations": [fake_org_response()],
        })
    return JSONResponse(fake_token_response())


@app.api_route("/api/auth/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def api_auth_mock(request: Request, path: str):
    lowered = path.lower()
    if "organization" in lowered or lowered.startswith("org"):
        return JSONResponse(fake_org_list_response())
    return JSONResponse(fake_user_response())


@app.get("/api/userinfo")
@app.get("/api/me")
@app.get("/api/user")
@app.get("/api/profile")
@app.get("/api/account")
async def api_userinfo_mock(request: Request):
    return JSONResponse(fake_user_response())


@app.get("/api/organizations")
async def api_orgs_mock(request: Request):
    return JSONResponse(fake_org_list_response())


@app.get("/api/organization")
@app.get("/api/organizations/{org_id}")
async def api_org_mock(request: Request, org_id: str = FAKE_ORG_UUID):
    return JSONResponse(fake_org_response())


@app.api_route("/api/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def api_anthropic_catch_all(request: Request, path: str):
    lowered = path.lower()
    if "oauth" in lowered or "token" in lowered:
        return JSONResponse(fake_token_response())
    if "organization" in lowered or lowered.startswith("org"):
        return JSONResponse(fake_org_list_response())
    if any(k in lowered for k in ("userinfo", "profile", "account", "user", "me")):
        return JSONResponse(fake_user_response())
    return JSONResponse({"ok": True})


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "deepseek_configured": bool(config.deepseek_api_key),
        "openai_configured": bool(config.openai_api_key),
        "custom_configured": bool(config.custom_api_key and config.custom_base_url),
        "default_backend": config.default_backend,
        "force_model": config.force_model or "(none)",
        "inline_image_policy": config.inline_image_policy,
        "proxy_dir": str(PROXY_DIR),
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import threading
    import uvicorn

    HTTPS_PORT = config.proxy_port + 1  # 9877 by default
    CERT_DIR = PROXY_DIR / "certs"
    SSL_CERT = str(CERT_DIR / "server-cert.pem")
    SSL_KEY = str(CERT_DIR / "server-key.pem")

    have_ssl = os.path.exists(SSL_CERT) and os.path.exists(SSL_KEY)

    print(f"\n{'='*60}")
    print(f"  Claude Science BYOK Proxy v2.1")
    print(f"  Dashboard → http://{config.proxy_host}:{config.proxy_port}/dashboard")
    if have_ssl:
        print(f"  HTTPS     → https://{config.proxy_host}:{HTTPS_PORT}")
        print(f"  Cert CN   → api.anthropic.com")
    print(f"  Health    → http://{config.proxy_host}:{config.proxy_port}/health")
    print(f"{'='*60}\n")

    if have_ssl:
        # Start HTTPS server in a background thread
        def run_https():
            uvicorn.run(
                app, host=config.proxy_host, port=HTTPS_PORT,
                ssl_keyfile=SSL_KEY, ssl_certfile=SSL_CERT,
                log_level="warning",
            )

        t = threading.Thread(target=run_https, daemon=True)
        t.start()
        print(f"[proxy] HTTPS server started on port {HTTPS_PORT}")

    # Start HTTP server (main thread)
    uvicorn.run(app, host=config.proxy_host, port=config.proxy_port, log_level="warning")
