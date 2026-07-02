# Agent Operating Manual

This repository is designed so an AI coding agent can configure Claude Science to use an OpenAI-compatible third-party API through a local Anthropic-compatible proxy.

Read this file first, then follow `docs/agent-runbook.md`.

## Prime Directive

Do not break the user's network.

Default to safe mode:

- Do not edit Clash, Surge, Shadowrocket, system proxy, VPN, DNS, or TUN settings.
- Do not reload network daemons.
- Do not write to `/etc/hosts`.
- Do not install a root CA.
- Do not bind port 443.
- Do not print, commit, or summarize API keys, OAuth tokens, private keys, or certificate private keys.

Only use advanced HTTPS interception after the user explicitly approves it for the current machine.

## Goal

Make Claude Science usable with DeepSeek, OpenAI, or another OpenAI-compatible API provider.
If the user needs image understanding, choose a vision-capable backend model and preserve image inputs instead of replacing them with text placeholders.

The safe path is:

1. Run a local HTTP proxy on `127.0.0.1:9876`.
2. Set `ANTHROPIC_BASE_URL=http://127.0.0.1:9876`.
3. Generate a local fake Claude Science OAuth token.
4. Configure an API key and model mapping in `config.json` or the dashboard.
5. Configure `model_aliases` and `model_list_mode=aliases` so Claude Science can show third-party model names.
6. Set `inline_image_policy=preserve` or `auto` only when the selected backend supports image input.
7. Start or restart Claude Science with `scripts/start-claude-science.sh`.
8. Verify `/v1/models` and `/v1/messages` reach the proxy and the backend succeeds.

## Repository Map

- `proxy.py`: FastAPI proxy, Anthropic Messages API to OpenAI Chat Completions translation.
- `setup-token.py`: creates a local fake Claude Science OAuth token.
- `start.sh`: foreground development start.
- `install.sh`: safe install, LaunchAgent, global `ANTHROPIC_BASE_URL`.
- `scripts/doctor.sh`: read-only state inspection.
- `scripts/install-safe.sh`: safe install entry point for agents.
- `scripts/patch-daemon-auth.sh`: byte-length-preserving OAuth/profile URL patch for the local daemon copy.
- `scripts/patch-daemon-models.sh`: byte-length-preserving model picker patch for the local daemon copy.
- `scripts/start-claude-science.sh`: refreshes token, reapplies daemon patches, and restarts the app.
- `scripts/verify-proxy.sh`: end-to-end proxy verification after provider config.
- `scripts/uninstall.sh`: removes LaunchAgent and launchctl env only.
- `setup-network.sh`: advanced HTTPS interception. Treat as opt-in only.
- `docs/agent-runbook.md`: step-by-step procedure for agents.
- `docs/network-interception.md`: advanced interception notes.
- `docs/troubleshooting.md`: failure modes and fixes.
- `config.example.json`: public, sanitized config template.

## Success Criteria

The task is complete when all of these pass:

```bash
./scripts/self-test.sh
./scripts/verify-proxy.sh
curl -sS http://127.0.0.1:9876/health
curl -sS http://127.0.0.1:9876/v1/models
curl -sS http://127.0.0.1:9876/v1/messages \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":32,"messages":[{"role":"user","content":"Say OK"}]}'
```

And `http://127.0.0.1:9876/api/recent-requests` shows a successful backend request.

For a vision-capable model, also run:

```bash
VERIFY_IMAGE=1 ./scripts/verify-proxy.sh
```

This sends a generated red PNG through the Anthropic image format. Do not claim image support is working until this passes.

## If Blocked

Use `scripts/doctor.sh` first. It is read-only and safe. Do not guess at network state.
