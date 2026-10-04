#!/usr/bin/env python3
"""Apply environment variables to config.json (Windows port of the mapping
in scripts/install-safe.sh).

Usage:
    python apply_env_config.py [--config PATH]

Reads the same environment variable names as install-safe.sh and writes
matching keys into config.json. Secrets are never printed; only key names.
"""

import argparse
import json
import os
from pathlib import Path

SIMPLE_MAPPING = {
    "DEEPSEEK_API_KEY": "deepseek_api_key",
    "OPENAI_API_KEY": "openai_api_key",
    "CUSTOM_API_KEY": "custom_api_key",
    "DEEPSEEK_BASE_URL": "deepseek_base_url",
    "OPENAI_BASE_URL": "openai_base_url",
    "CUSTOM_BASE_URL": "custom_base_url",
    "DEFAULT_BACKEND": "default_backend",
    "FORCE_MODEL": "force_model",
    "MODEL_LIST_MODE": "model_list_mode",
    "MODEL_MENU_STRATEGY": "model_menu_strategy",
    "DEFAULT_MAX_TOKENS_CAP": "default_max_tokens_cap",
    "DEEPSEEK_UPSTREAM_MODE": "deepseek_upstream_mode",
    "OPENAI_UPSTREAM_MODE": "openai_upstream_mode",
    "CUSTOM_UPSTREAM_MODE": "custom_upstream_mode",
    "PROXY_AUTH_TOKEN": "proxy_auth_token",
    "PROXY_AUTH_MODE": "proxy_auth_mode",
    "REASONING_CONTENT_POLICY": "reasoning_content_policy",
    "INLINE_IMAGE_POLICY": "inline_image_policy",
    "PROXY_HOST": "proxy_host",
    "PROXY_PORT": "proxy_port",
}

JSON_MAPPING = {
    "DEEPSEEK_MODEL_MAP": "deepseek_model_map",
    "OPENAI_MODEL_MAP": "openai_model_map",
    "CUSTOM_MODEL_MAP": "custom_model_map",
    "MODEL_ALIASES": "model_aliases",
    "MODEL_TOKEN_CAPS": "model_token_caps",
    "PROVIDER_PROFILES": "provider_profiles",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    default_config = Path(__file__).resolve().parent.parent.parent / "config.json"
    parser.add_argument("--config", default=str(default_config))
    args = parser.parse_args()

    path = Path(args.config).expanduser()
    if not path.is_file():
        print(f"config.json not found: {path}")
        return 1
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"config.json is not valid JSON: {e}")
        return 1

    changed = []
    for env_key, config_key in SIMPLE_MAPPING.items():
        value = os.environ.get(env_key)
        if value:
            if config_key == "proxy_port":
                try:
                    value = int(value)
                except ValueError:
                    print(f"PROXY_PORT must be an integer, got: {value!r}")
                    return 1
            data[config_key] = value
            changed.append(config_key)

    for env_key, config_key in JSON_MAPPING.items():
        value = os.environ.get(env_key)
        if value:
            try:
                data[config_key] = json.loads(value)
            except Exception as e:
                print(f"{env_key} is not valid JSON: {e}")
                return 1
            changed.append(config_key)

    if changed:
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        safe_changed = [k for k in changed if not k.endswith("_api_key")]
        secret_count = sum(1 for k in changed if k.endswith("_api_key"))
        names = ", ".join(safe_changed) if safe_changed else "(only secrets)"
        print(f"Applied config from environment: {names}; secrets updated: {secret_count}")
    else:
        print("No environment overrides found; config.json left unchanged.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
