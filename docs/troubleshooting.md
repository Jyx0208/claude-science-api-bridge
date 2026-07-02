# Troubleshooting

## Proxy Is Not Running

Check:

```bash
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

- `fallback`: use normal content, or reasoning if content is empty.
- `always`: prepend reasoning content when present.
- `never`: ignore reasoning content.

Set this in `config.json`:

```json
{
  "reasoning_content_policy": "fallback"
}
```

## Port 9876 Is Busy

Find the process:

```bash
lsof -nP -iTCP:9876 -sTCP:LISTEN
```

Either stop it or set a different `PROXY_PORT`, then update `ANTHROPIC_BASE_URL`.

