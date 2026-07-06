#!/usr/bin/env python3
"""Sync Claude Science API Bridge into CC Switch providers.

This script intentionally avoids system proxy, DNS, certificates, Clash, and
network settings. It only writes CC Switch's local SQLite provider database
after creating a timestamped backup.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any


PROJECT_DIR = Path(__file__).resolve().parents[1]
CONFIG_PATH = PROJECT_DIR / "config.json"
CCSWITCH_DIR = Path.home() / ".cc-switch"
CCSWITCH_DB = CCSWITCH_DIR / "cc-switch.db"
CCSWITCH_SETTINGS = CCSWITCH_DIR / "settings.json"
PROVIDER_ID = "claude-science-api-bridge"
PROVIDER_NAME = "Claude Science API Bridge"
PROFILE_PROVIDER_PREFIX = "claude-science-profile-"
CLAUDE_SCIENCE_APP_TYPE = "claude-science"
COMPAT_APP_TYPE = "claude"
DEFAULT_ROUTES = [
    ("claude-sonnet-5", "ANTHROPIC_DEFAULT_SONNET_MODEL"),
    ("claude-opus-4-8", "ANTHROPIC_DEFAULT_OPUS_MODEL"),
    ("claude-haiku-4-5", "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
    ("claude-fable-5", "ANTHROPIC_DEFAULT_FABLE_MODEL"),
]


def load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default
    except Exception as exc:
        raise SystemExit(f"Failed to read JSON {path}: {exc}") from exc


def now_ms() -> int:
    return int(time.time() * 1000)


def bridge_base_url(cfg: dict[str, Any]) -> str:
    host = str(cfg.get("proxy_host") or "127.0.0.1").strip() or "127.0.0.1"
    port = int(cfg.get("proxy_port") or 9876)
    url = f"http://{host}:{port}"
    token = str(cfg.get("proxy_auth_token") or "").strip()
    mode = str(cfg.get("proxy_auth_mode") or "optional").strip().lower()
    if token and mode == "required":
        url = f"{url}/{token}"
    return url


def display_url(url: str) -> str:
    parts = url.split("/")
    if len(parts) > 3:
        return "/".join(parts[:3] + ["****"])
    return url


def normalize_alias(raw: Any) -> dict[str, str] | None:
    if isinstance(raw, str):
        value = raw.strip()
        if not value:
            return None
        return {"id": value, "model": value, "display_name": value, "backend": ""}
    if not isinstance(raw, dict):
        return None
    alias_id = str(raw.get("id") or raw.get("model") or "").strip()
    model = str(raw.get("model") or alias_id).strip()
    if not alias_id and not model:
        return None
    alias_id = alias_id or model
    display_name = str(raw.get("display_name") or raw.get("name") or model or alias_id).strip()
    return {
        "id": alias_id,
        "model": model or alias_id,
        "display_name": display_name or model or alias_id,
        "backend": str(raw.get("backend") or "").strip(),
    }


def aliases_from_config(cfg: dict[str, Any]) -> list[dict[str, str]]:
    aliases = [a for a in (normalize_alias(x) for x in cfg.get("model_aliases") or []) if a]
    if aliases:
        return aliases
    model = str(cfg.get("force_model") or "").strip()
    if model:
        return [{"id": "claude-opus-4-8", "model": model, "display_name": model, "backend": str(cfg.get("default_backend") or "")}]
    return [{"id": "claude-opus-4-8", "model": "claude-opus-4-8", "display_name": "Claude Science Bridge", "backend": ""}]


def backend_key(cfg: dict[str, Any], backend: str) -> str:
    if backend == "deepseek":
        return str(cfg.get("deepseek_api_key") or "").strip()
    if backend == "openai":
        return str(cfg.get("openai_api_key") or "").strip()
    return str(cfg.get("custom_api_key") or "").strip()


def backend_base_url(cfg: dict[str, Any], backend: str) -> str:
    if backend == "deepseek":
        return str(cfg.get("deepseek_base_url") or "https://api.deepseek.com").strip()
    if backend == "openai":
        return str(cfg.get("openai_base_url") or "https://api.openai.com").strip()
    return str(cfg.get("custom_base_url") or "").strip()


def backend_upstream_mode(cfg: dict[str, Any], backend: str) -> str:
    key = f"{backend}_upstream_mode" if backend in {"deepseek", "openai", "custom"} else "custom_upstream_mode"
    return str(cfg.get(key) or "openai").strip().lower()


def profile_provider_id(profile_id: str) -> str:
    safe = "".join(ch if ch.isalnum() or ch in "-_." else "-" for ch in str(profile_id or "").strip())
    safe = safe.strip("-") or str(now_ms())
    return PROFILE_PROVIDER_PREFIX + safe


def normalize_profile_model(raw: Any) -> dict[str, str] | None:
    if isinstance(raw, str):
        value = raw.strip()
        if not value:
            return None
        return {"id": value, "model": value, "display_name": value}
    if not isinstance(raw, dict):
        return None
    model = str(raw.get("model") or raw.get("id") or raw.get("name") or "").strip()
    if not model:
        return None
    return {
        "id": model,
        "model": model,
        "display_name": str(raw.get("display_name") or raw.get("label") or raw.get("name") or model).strip(),
    }


def bridge_profiles(cfg: dict[str, Any]) -> list[dict[str, Any]]:
    profiles = [p for p in (cfg.get("provider_profiles") or []) if isinstance(p, dict)]
    if profiles:
        return profiles
    backend = str(cfg.get("default_backend") or "custom").strip().lower()
    aliases = aliases_from_config(cfg)
    return [{
        "id": "current",
        "label": active_profile_label(cfg) or "当前 Bridge 配置",
        "backend": backend,
        "base_url": backend_base_url(cfg, backend),
        "upstream_mode": backend_upstream_mode(cfg, backend),
        "api_key": backend_key(cfg, backend),
        "default_model": str(cfg.get("force_model") or (aliases[0]["model"] if aliases else "")).strip(),
        "models": [{"id": a["model"], "model": a["model"], "display_name": a["display_name"]} for a in aliases],
        "inline_image_policy": cfg.get("inline_image_policy") or "auto",
    }]


def ordered_bridge_profiles(cfg: dict[str, Any]) -> list[dict[str, Any]]:
    profiles = bridge_profiles(cfg)
    active_id = str(cfg.get("active_profile_id") or "").strip()
    if not active_id:
        return profiles
    ordered = sorted(
        enumerate(profiles),
        key=lambda item: (
            0 if str(item[1].get("id") or "").strip() == active_id else 1,
            item[0],
        ),
    )
    return [profile for _, profile in ordered]


def rows_from_bridge_profiles(cfg: dict[str, Any], app_type: str) -> dict[str, dict[str, Any]]:
    rows = {}
    for profile in ordered_bridge_profiles(cfg):
        backend = str(profile.get("backend") or profile.get("provider") or "custom").strip().lower()
        if backend not in {"deepseek", "openai", "custom"}:
            backend = "custom"
        base_url = str(profile.get("base_url") or backend_base_url(cfg, backend)).strip()
        api_key = str(profile.get("api_key") or backend_key(cfg, backend)).strip()
        upstream_mode = str(profile.get("upstream_mode") or backend_upstream_mode(cfg, backend)).strip().lower()
        models = [m for m in (normalize_profile_model(x) for x in profile.get("models") or []) if m]
        default_model = str(profile.get("default_model") or (models[0]["model"] if models else "")).strip()
        if default_model and not any(m["model"] == default_model for m in models):
            models.insert(0, {"id": default_model, "model": default_model, "display_name": default_model})
        if not base_url or not api_key or not models:
            continue

        provider_id = profile_provider_id(str(profile.get("id") or profile.get("label") or default_model))
        env = {
            "ANTHROPIC_BASE_URL": base_url,
            "ANTHROPIC_AUTH_TOKEN": api_key,
            "ANTHROPIC_MODEL": default_model or models[0]["model"],
            "ENABLE_TOOL_SEARCH": "true",
        }
        role_models = [m["model"] for m in models]
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = role_models[0]
        env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = role_models[min(1, len(role_models) - 1)]
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = role_models[min(1, len(role_models) - 1)]
        env["ANTHROPIC_DEFAULT_FABLE_MODEL"] = role_models[0]
        for key in [
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
        ]:
            env[key + "_NAME"] = env[key]

        rows[provider_id] = {
            "id": provider_id,
            "name": str(profile.get("label") or profile.get("name") or provider_id).strip(),
            "settings_config": {"env": env, "skipDangerousModePermissionPrompt": "True"},
            "website_url": str(profile.get("website_url") or profile.get("homepage") or "http://127.0.0.1:9876/dashboard"),
            "category": "custom",
            "created_at": now_ms(),
            "notes": "Claude Science Provider，由 Claude Science API Bridge 同步到 CC Switch。",
            "icon": "claude",
            "icon_color": "#2563eb",
            "base_url": base_url,
            "meta": {
                "app": "Claude Science",
                "commonConfigEnabled": False,
                "endpointAutoSelect": False,
                "apiFormat": "anthropic" if upstream_mode in {"anthropic", "native", "passthrough"} else "openai_chat",
                "managedBy": "claude-science-api-bridge",
                "bridgeProfileId": str(profile.get("id") or ""),
                "inlineImagePolicy": str(profile.get("inline_image_policy") or cfg.get("inline_image_policy") or "auto"),
            },
        }
    if rows:
        return rows
    fallback = build_provider_rows(cfg)[app_type]
    return {fallback["id"]: fallback}


def active_profile_label(cfg: dict[str, Any]) -> str:
    active_id = str(cfg.get("active_profile_id") or "").strip()
    for profile in cfg.get("provider_profiles") or []:
        if isinstance(profile, dict) and str(profile.get("id") or "") == active_id:
            return str(profile.get("label") or profile.get("name") or "").strip()
    backend = str(cfg.get("default_backend") or "").strip()
    return backend.upper() if backend else ""


def route_map_from_config(cfg: dict[str, Any]) -> dict[str, dict[str, Any]]:
    aliases = aliases_from_config(cfg)
    by_id = {a["id"]: a for a in aliases}
    first = aliases[0]
    role_fallback = {
        "claude-sonnet-5": "claude-sonnet-5",
        "claude-opus-4-8": "claude-opus-4-8",
        "claude-haiku-4-5": "claude-sonnet-5",
        "claude-fable-5": "claude-opus-4-8",
    }
    routes: dict[str, dict[str, Any]] = {}
    for route_id, _ in DEFAULT_ROUTES:
        alias = by_id.get(route_id) or by_id.get(role_fallback[route_id]) or first
        routes[route_id] = {
            "model": alias["id"],
            "labelOverride": alias["display_name"],
            "supports1m": True,
        }
    return routes


def build_settings_config(cfg: dict[str, Any], base_url: str, routes: dict[str, dict[str, Any]]) -> dict[str, Any]:
    env: dict[str, str] = {
        "ANTHROPIC_BASE_URL": base_url,
        "ANTHROPIC_AUTH_TOKEN": "cs-bridge-local",
        "ENABLE_TOOL_SEARCH": "true",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    }
    primary = routes.get("claude-opus-4-8") or next(iter(routes.values()))
    env["ANTHROPIC_MODEL"] = str(primary["model"])
    for route_id, env_key in DEFAULT_ROUTES:
        value = str(routes[route_id]["model"])
        env[env_key] = value
        env[env_key + "_NAME"] = value
    return {
        "env": env,
        "skipDangerousModePermissionPrompt": "True",
    }


def notes(cfg: dict[str, Any], base_url: str) -> str:
    label = active_profile_label(cfg)
    suffix = f" 当前 Bridge Provider：{label}。" if label else ""
    return (
        "由 Claude Science API Bridge 自动同步。"
        "在 Bridge 控制台切换第三方模型后可再次同步到 CC Switch。"
        f" Base URL: {display_url(base_url)}。{suffix}"
    )


def build_provider_rows(cfg: dict[str, Any]) -> dict[str, dict[str, Any]]:
    base_url = bridge_base_url(cfg)
    routes = route_map_from_config(cfg)
    settings_config = build_settings_config(cfg, base_url, routes)
    common = {
        "id": PROVIDER_ID,
        "name": PROVIDER_NAME,
        "settings_config": settings_config,
        "website_url": "http://127.0.0.1:9876/dashboard",
        "category": "custom",
        "created_at": now_ms(),
        "notes": notes(cfg, base_url),
        "icon": "claude",
        "icon_color": "#2563eb",
        "base_url": base_url,
    }
    return {
        CLAUDE_SCIENCE_APP_TYPE: {
            **common,
            "meta": {
                "app": "Claude Science",
                "commonConfigEnabled": False,
                "endpointAutoSelect": False,
                "apiFormat": "anthropic",
                "managedBy": "claude-science-api-bridge",
                "bridgeDashboardUrl": "http://127.0.0.1:9876/dashboard",
                "bridgeConfigPath": str(CONFIG_PATH),
                "requiresCcSwitchSourcePatch": True,
            },
        },
        COMPAT_APP_TYPE: {
            **common,
            "name": "Claude Science API Bridge (compat)",
            "notes": (
                "兼容入口：写入 CC Switch 的 Claude Code 面板，仅用于暂时查看/借用配置。"
                "它不是 Claude Science 原生入口；原生入口应使用 app_type=claude-science。"
            ),
            "meta": {
                "app": "Claude Science",
                "commonConfigEnabled": False,
                "apiFormat": "anthropic",
                "endpointAutoSelect": False,
                "managedBy": "claude-science-api-bridge",
                "compatOnly": True,
            },
        },
    }


def ensure_db() -> None:
    if not CCSWITCH_DB.exists():
        raise SystemExit(f"CC Switch database not found: {CCSWITCH_DB}")


def backup_file(path: Path) -> str:
    backups = path.parent / "backups"
    backups.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    target = backups / f"{path.name}-{stamp}"
    shutil.copy2(path, target)
    return str(target)


def next_sort_index(con: sqlite3.Connection, app_type: str) -> int:
    row = con.execute("select max(coalesce(sort_index, 0)) from providers where app_type = ?", (app_type,)).fetchone()
    return int(row[0] or 0) + 10


def save_provider(con: sqlite3.Connection, app_type: str, row: dict[str, Any], activate: bool) -> str:
    existing = con.execute(
        "select is_current, in_failover_queue, sort_index, created_at from providers where id = ? and app_type = ?",
        (row["id"], app_type),
    ).fetchone()
    is_current = int(existing[0]) if existing else 0
    in_failover_queue = int(existing[1]) if existing else 0
    sort_index = int(existing[2]) if existing and existing[2] is not None else next_sort_index(con, app_type)
    created_at = int(existing[3]) if existing and existing[3] is not None else row["created_at"]
    if activate:
        is_current = 1

    payload = (
        row["id"],
        app_type,
        row["name"],
        json.dumps(row["settings_config"], ensure_ascii=False, indent=2),
        row["website_url"],
        row["category"],
        created_at,
        sort_index,
        row["notes"],
        row["icon"],
        row["icon_color"],
        json.dumps(row["meta"], ensure_ascii=False, indent=2),
        is_current,
        in_failover_queue,
        "1.0",
        None,
        None,
        None,
    )
    if activate:
        con.execute("update providers set is_current = 0 where app_type = ?", (app_type,))
    con.execute(
        """
        insert into providers (
            id, app_type, name, settings_config, website_url, category, created_at,
            sort_index, notes, icon, icon_color, meta, is_current, in_failover_queue,
            cost_multiplier, limit_daily_usd, limit_monthly_usd, provider_type
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        on conflict(id, app_type) do update set
            name = excluded.name,
            settings_config = excluded.settings_config,
            website_url = excluded.website_url,
            category = excluded.category,
            sort_index = excluded.sort_index,
            notes = excluded.notes,
            icon = excluded.icon,
            icon_color = excluded.icon_color,
            meta = excluded.meta,
            is_current = excluded.is_current,
            in_failover_queue = excluded.in_failover_queue,
            cost_multiplier = excluded.cost_multiplier,
            provider_type = excluded.provider_type
        """,
        payload,
    )
    con.execute("delete from provider_endpoints where provider_id = ? and app_type = ?", (row["id"], app_type))
    con.execute(
        "insert into provider_endpoints (provider_id, app_type, url, added_at) values (?, ?, ?, ?)",
        (row["id"], app_type, row["base_url"], now_ms()),
    )
    return row["id"]


def cleanup_managed_providers(con: sqlite3.Connection, app_type: str, keep_ids: set[str]) -> None:
    if app_type != CLAUDE_SCIENCE_APP_TYPE:
        return
    managed = [
        str(row[0])
        for row in con.execute(
            "select id from providers where app_type = ? and (id = ? or id like ?)",
            (app_type, PROVIDER_ID, PROFILE_PROVIDER_PREFIX + "%"),
        )
    ]
    for provider_id in managed:
        if provider_id in keep_ids:
            continue
        con.execute("delete from provider_endpoints where provider_id = ? and app_type = ?", (provider_id, app_type))
        con.execute("delete from providers where id = ? and app_type = ?", (provider_id, app_type))


def update_settings_current(current_by_app: dict[str, str]) -> str | None:
    if not CCSWITCH_SETTINGS.exists():
        return None
    backup = backup_file(CCSWITCH_SETTINGS)
    data = load_json(CCSWITCH_SETTINGS, {})
    if COMPAT_APP_TYPE in current_by_app:
        data["currentProviderClaude"] = current_by_app[COMPAT_APP_TYPE]
    if CLAUDE_SCIENCE_APP_TYPE in current_by_app:
        data["currentProviderClaudeScience"] = current_by_app[CLAUDE_SCIENCE_APP_TYPE]
    CCSWITCH_SETTINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    os.chmod(CCSWITCH_SETTINGS, 0o600)
    return backup


def sync_to_ccswitch(app_types: list[str], activate: bool, backup: bool) -> dict[str, Any]:
    ensure_db()
    cfg = load_json(CONFIG_PATH, {})
    rows = build_provider_rows(cfg)
    db_backup = backup_file(CCSWITCH_DB) if backup else ""
    written: list[dict[str, str]] = []
    current_by_app: dict[str, str] = {}
    con = sqlite3.connect(CCSWITCH_DB)
    try:
        with con:
            for app_type in app_types:
                app_rows = rows_from_bridge_profiles(cfg, app_type) if app_type == CLAUDE_SCIENCE_APP_TYPE else {PROVIDER_ID: rows[app_type]}
                cleanup_managed_providers(con, app_type, set(app_rows.keys()))
                first = True
                for row in app_rows.values():
                    save_provider(con, app_type, row, activate and first)
                    if first:
                        current_by_app[app_type] = row["id"]
                    written.append({
                        "app_type": app_type,
                        "id": row["id"],
                        "name": row["name"],
                        "base_url": display_url(row["base_url"]),
                    })
                    first = False
    finally:
        con.close()

    settings_backup = update_settings_current(current_by_app) if activate else None
    return {
        "ok": True,
        "provider_id": PROVIDER_ID,
        "provider_name": PROVIDER_NAME,
        "written": written,
        "activated": activate,
        "db_backup": db_backup,
        "settings_backup": settings_backup or "",
        "message": "Claude Science API Bridge has been synced into CC Switch.",
    }


def status() -> dict[str, Any]:
    if not CCSWITCH_DB.exists():
        return {"ok": False, "installed": False, "error": f"CC Switch database not found: {CCSWITCH_DB}"}
    cfg = load_json(CONFIG_PATH, {})
    settings = load_json(CCSWITCH_SETTINGS, {}) if CCSWITCH_SETTINGS.exists() else {}
    settings_current = str(settings.get("currentProviderClaudeScience") or "").strip()
    active_profile_id = str(cfg.get("active_profile_id") or "").strip()
    bridge_current = profile_provider_id(active_profile_id) if active_profile_id else ""
    con = sqlite3.connect(CCSWITCH_DB)
    con.row_factory = sqlite3.Row
    try:
        rows = [
            dict(r)
            for r in con.execute(
                "select app_type,id,name,is_current from providers where id = ? or id like ? order by app_type,name",
                (PROVIDER_ID, PROFILE_PROVIDER_PREFIX + "%"),
            )
        ]
    finally:
        con.close()
    effective_current = settings_current or bridge_current
    if effective_current and not any(int(row.get("is_current") or 0) for row in rows):
        for row in rows:
            if row.get("app_type") == CLAUDE_SCIENCE_APP_TYPE and row.get("id") == effective_current:
                row["is_current"] = 1
    return {
        "ok": True,
        "installed": bool(rows),
        "native_app_type": CLAUDE_SCIENCE_APP_TYPE,
        "native_supported_by_current_ccswitch": False,
        "native_note": (
            "Current upstream CC Switch 3.16.x hard-codes app types and does not show "
            "claude-science without a source patch."
        ),
        "provider_id": PROVIDER_ID,
        "provider_name": PROVIDER_NAME,
        "current_provider_id": effective_current,
        "settings_current_provider_id": settings_current,
        "bridge_current_provider_id": bridge_current,
        "rows": rows,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Sync Claude Science API Bridge into CC Switch.")
    parser.add_argument(
        "--app",
        action="append",
        choices=[CLAUDE_SCIENCE_APP_TYPE, COMPAT_APP_TYPE],
        help="App type to sync. Default: claude-science. Use --app claude only for the temporary Claude Code compatibility entry.",
    )
    parser.add_argument(
        "--compat-claude-code",
        action="store_true",
        help="Also add a temporary compatibility provider under CC Switch's Claude Code panel.",
    )
    parser.add_argument("--activate", action="store_true", help="Mark the Bridge provider as current in CC Switch DB/settings.")
    parser.add_argument("--no-backup", action="store_true", help="Skip SQLite backup before writing.")
    parser.add_argument("--status", action="store_true", help="Only print integration status.")
    parser.add_argument("--json", action="store_true", help="Print JSON output.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app_types = args.app or [CLAUDE_SCIENCE_APP_TYPE]
    if args.compat_claude_code and COMPAT_APP_TYPE not in app_types:
        app_types.append(COMPAT_APP_TYPE)
    try:
        result = status() if args.status else sync_to_ccswitch(
            app_types=app_types,
            activate=args.activate,
            backup=not args.no_backup,
        )
    except SystemExit as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:
        result = {"ok": False, "error": str(exc)}

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        if result.get("ok"):
            if args.status:
                print(f"installed={result.get('installed')} provider={PROVIDER_ID}")
            else:
                print(result.get("message") or "Synced.")
                for row in result.get("written", []):
                    print(f"- {row['app_type']}: {row['name']} ({row['base_url']})")
                if result.get("db_backup"):
                    print(f"Backup: {result['db_backup']}")
                if result.get("activated"):
                    print("Activated in CC Switch DB/settings. Restart CC Switch if the UI is already open.")
        else:
            print(result.get("error") or "Unknown error", file=sys.stderr)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
