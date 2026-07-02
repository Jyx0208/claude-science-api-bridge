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

## Backend 400: Invalid Tool Schema

The proxy sanitizes Claude tool schemas before sending them to OpenAI-compatible APIs. If this still appears, capture only the backend error text from `proxy.log`. Do not log full prompts or API keys.

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

## SSL Certificate Verify Failed When Proxy Calls Backend

The proxy uses `trust_env=False` for backend HTTP clients so Claude Science CA variables do not affect DeepSeek/OpenAI TLS. If this error appears, confirm the running process is using the latest `proxy.py`.

## Claude Science Says Session Is Invalid

Try:

```bash
python3 setup-token.py
pkill -f "claude-science serve" 2>/dev/null || true
open -a "Claude Science"
```

Then inspect:

```bash
curl -sS http://127.0.0.1:9876/api/recent-requests
```

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

First check whether the backend model actually supports vision input. Text-only models should use:

```json
{
  "inline_image_policy": "omit"
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
