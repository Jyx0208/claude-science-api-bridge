# Troubleshooting

## Proxy Is Not Running

Check:

```bash
./scripts/doctor.sh
launchctl print gui/$(id -u)/com.byok.claude-science-proxy
tail -n 120 ~/.claude-science/logs/proxy.log
tail -n 120 ~/.claude-science/logs/proxy-error.log
```

Restart:

```bash
launchctl kickstart -k gui/$(id -u)/com.byok.claude-science-proxy
```

On Linux, check and restart the user service:

```bash
./scripts/doctor.sh
systemctl --user status claude-science-api-bridge.service
systemctl --user restart claude-science-api-bridge.service
journalctl --user -u claude-science-api-bridge.service -n 120 --no-pager
```

If systemd user is unavailable, `scripts/install-safe.sh` starts a fallback user process and writes its PID to `~/.claude-science/proxy.pid`.

## Backend 400: Invalid Tool Schema

The proxy sanitizes Claude tool schemas before sending them to OpenAI-compatible APIs. If this still appears, capture only the backend error text from `proxy.log`. Do not log full prompts or API keys.

## Backend 400: max_tokens Too Large

Some providers reject the large `max_tokens` values that Claude Science may request.

Set a per-model cap:

```json
{
  "model_token_caps": {
    "provider-model-name": 8192
  }
}
```

Then restart the proxy and rerun `./scripts/verify-proxy.sh`.

## Tool Call Markers Appear As Text

Some OpenAI-compatible providers may emit native tool-call markers such as:

```text
<|tool_calls_section_begin|><|tool_call_begin|>functions.python:0<|tool_call_argument_begin|>{...}
```

The proxy converts these markers into Anthropic `tool_use` blocks in both streaming and non-streaming responses. If the markers still appear in Claude Science:

1. Restart the LaunchAgent so the latest `proxy.py` is running.
2. Run `./scripts/self-test.sh` and confirm the embedded tool-call tests pass.
3. Check `http://127.0.0.1:9876/api/recent-requests` to confirm Claude Science is hitting this proxy.

For SiliconFlow Kimi, forced Anthropic tool choices are sent as OpenAI `auto` because the provider only accepts `auto` and `none`. This avoids backend 400 errors while still allowing the model to call tools.

## Claude Science Shows Connection Issue

Check the local proxy and recent requests first:

```bash
curl -sS http://127.0.0.1:9876/health
curl -sS http://127.0.0.1:9876/api/recent-requests
tail -n 120 ~/.claude-science/logs/proxy.log
tail -n 120 ~/.claude-science/logs/proxy-error.log
```

For slow streaming providers, the proxy emits Anthropic-style `ping` events while the upstream stream is idle after `message_start`. This prevents Claude Science from seeing a quiet stream as a dropped connection. The heartbeat interval defaults to 3 seconds and can be adjusted with `STREAM_HEARTBEAT_SECONDS`.

If this message appears repeatedly:

1. Run `./scripts/self-test.sh` and confirm the heartbeat and streaming tests pass.
2. Run `./scripts/verify-proxy.sh` to confirm normal backend calls still work.
3. Check whether recent requests show backend errors, timeouts, or only successful slow streams.
4. Do not modify Clash, DNS, TUN, `/etc/hosts`, system proxy, certificates, or port 443 as a first response.

## Requests Return 403 After Enabling Path-Secret

If `proxy_auth_mode=required`, Claude Science must use a base URL with the secret path:

```text
http://127.0.0.1:9876/<secret>
```

Run:

```bash
./scripts/start-claude-science.sh
./scripts/verify-proxy.sh
```

Both scripts read `config.json`, append the secret automatically, and mask it in output. Do not paste the raw secret into issue reports or chat logs.

## SSL Certificate Verify Failed When Proxy Calls Backend

The proxy uses `trust_env=False` for backend HTTP clients so Claude Science CA variables do not affect DeepSeek/OpenAI TLS. If this error appears, confirm the running process is using the latest `proxy.py`.

## Claude Science Says Session Is Invalid

Try:

```bash
python3 setup-token.py
./scripts/start-claude-science.sh
```

Then inspect:

```bash
curl -sS http://127.0.0.1:9876/api/recent-requests
```

Expected auth/profile requests after startup:

- `GET /api/oauth/profile` returns 200
- `GET /api/oauth/usage` returns 200
- organization bootstrap/plugin/skill paths under `/api/oauth/organizations/...` return 200

If logs still show `claudeAiFetch: 401 and refresh failed` or `mcp.bootstrap: org unresolved`, rerun:

```bash
./scripts/patch-daemon-auth.sh
./scripts/start-claude-science.sh
```

The auth patch must rewrite both `https://api.anthropic.com` and `https://claude.ai` to the local bridge. Do not solve this by changing Clash, DNS, TUN, `/etc/hosts`, system proxy, certificates, or port 443.

## Dashboard Shows Internal Server Error Or Database Banner

Claude Science may show:

```text
Claude Science is hitting repeated database errors...
Failed to load dashboard
Internal server error
```

First separate old log noise from the current daemon:

```bash
./scripts/doctor.sh
sqlite3 ~/.claude-science/operon-cli.db 'PRAGMA integrity_check;'
sqlite3 ~/.claude-science/operon-cli.db 'PRAGMA quick_check;'
```

Then restart cleanly:

```bash
mkdir -p ~/.claude-science/backups
cp -p ~/.claude-science/operon*.db* ~/.claude-science/backups/ 2>/dev/null || true
./scripts/start-claude-science.sh
```

After restart, inspect only the new daemon PID in `~/.claude-science/logs/server-*.log`. Historical `SQLiteError: file is not a database` lines from older PIDs do not prove the current database is still broken. If the same error returns under the new PID even though `integrity_check` is `ok`, stop Claude Science before any database repair and keep the backup.

## Model Picker Still Shows Opus / Sonnet / Haiku

Claude Science may render its picker from hard-coded strings in the local daemon copy, so `/v1/models` alone is not always enough.

Do not change Clash, DNS, TUN, `/etc/hosts`, system proxy, certificates, or port 443 for this issue.

Run:

```bash
./scripts/patch-daemon-models.sh
./scripts/start-claude-science.sh
curl -sS http://127.0.0.1:9876/v1/models
```

Expected:

- `/v1/models` returns Claude-compatible menu slots such as `claude-opus-4-8`, with third-party display names.
- Claude Science model picker shows the configured third-party display name, such as `Kimi K2.6 Pro++`.
- Requests in `/api/recent-requests` route to the real backend model configured in `model_aliases`.

If you want the raw provider model IDs, set `model_menu_strategy=real_ids`, but some Claude Science builds may hide non-`claude-*` IDs or move them into overflow UI. The default `claude_compatible` strategy is usually more reliable.

If the patch script reports an unsupported daemon build, keep the app usable through `ANTHROPIC_BASE_URL` and inspect the current daemon strings before writing a new byte-length-preserving patch. Do not patch `/Applications/Claude Science.app` unless the user explicitly asks.

## DeepSeek Returns Empty Content

Some reasoning models put early tokens in `reasoning_content`. The proxy supports:

- `never`: ignore reasoning content. This is the default and safest setting.
- `fallback`: use normal content, or reasoning if content is empty. This may expose provider scratchpad text.
- `always`: prepend reasoning content when present. Use only for debugging.

Set this in `config.json`:

```json
{
  "reasoning_content_policy": "never"
}
```

If Claude Science displays text such as `The user said...`, `The session was resumed...`, `Let me check...`, or `用户要求继续分析...`, the backend is leaking scratchpad-style planning in normal content. The proxy strips common trace preambles, especially before tool calls. Restart the proxy and run `./scripts/self-test.sh` to verify the trace-filter tests pass.

## Image Input Fails

First check whether the backend model actually supports vision input. Text-only models can either omit images or use a configured vision fallback.

```json
{
  "image_fallback_mode": "auto",
  "image_fallback_backend": "custom",
  "image_fallback_model": "Pro/moonshotai/Kimi-K2.6"
}
```

Vision models should use:

```json
{
  "inline_image_policy": "preserve"
}
```

Then run:

```bash
VERIFY_IMAGE=1 ./scripts/verify-proxy.sh
```

If a DeepSeek request contains images, the proxy should log an image fallback and route that single request to the configured vision model instead of sending image blocks to DeepSeek directly.

For SiliconFlow Kimi, inline PNG/WebP/GIF/HEIC images are converted locally to JPEG data URLs before sending to the provider. Very tiny or malformed images may still be rejected by the provider; test with a normal screenshot or the generated verification image.

## Port 9876 Is Busy

Find the process:

```bash
lsof -nP -iTCP:9876 -sTCP:LISTEN
```

Either stop it or set a different `PROXY_PORT`, then update `ANTHROPIC_BASE_URL`.

## Verification Fails

Run:

```bash
./scripts/doctor.sh
./scripts/self-test.sh
./scripts/verify-proxy.sh
```

If `verify-proxy.sh` says no backend API key is configured, configure the dashboard or write the key to local `config.json`. Do not commit `config.json`.
