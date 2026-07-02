# Claude Science Third-Party API Proxy

Local Anthropic-compatible proxy for Claude Science on macOS. It lets Claude Science use DeepSeek, OpenAI, or another OpenAI-compatible API provider.

This repository is intentionally written as an agent-readable runbook. An AI coding agent can read `AGENTS.md`, follow `docs/agent-runbook.md`, run the safe scripts, and verify the setup without changing the user's network stack.

## What It Does

- Provides a local Anthropic Messages API endpoint on `127.0.0.1:9876`.
- Converts Anthropic Messages requests to OpenAI Chat Completions requests.
- Converts OpenAI-compatible responses back to Anthropic-style responses.
- Supports streaming, non-streaming, tool calls, tool results, image blocks, and basic token counting.
- Creates a local fake Claude Science OAuth token so the app can start without a real Anthropic session.
- Provides a dashboard at `http://127.0.0.1:9876/dashboard`.
- Installs as a macOS LaunchAgent in safe mode.

## Safe Default

The default install does not edit:

- Clash, VPN, TUN, DNS, or system proxy settings
- `/etc/hosts`
- System keychain trust
- Port `443`

Advanced HTTPS interception exists, but it is opt-in. Read `docs/network-interception.md` first.

## Quick Start

```bash
cd ~/.claude-science/proxy
./install.sh
open http://127.0.0.1:9876/dashboard
```

In the dashboard:

1. Configure DeepSeek, OpenAI, or Custom OpenAI-compatible API.
2. Set `default_backend`.
3. Set `force_model` to the real model name your provider expects.
4. Start Claude Science:

```bash
open -a "Claude Science"
```

## Agent Quick Start

If you are an AI agent, read these files in order:

1. `AGENTS.md`
2. `docs/agent-runbook.md`
3. `docs/troubleshooting.md`
4. `docs/network-interception.md` only if explicitly approved
5. `docs/github-publishing.md` before publishing

Then run:

```bash
./scripts/doctor.sh
./scripts/install-safe.sh
```

## Provider Examples

DeepSeek:

```json
{
  "deepseek_api_key": "REDACTED",
  "deepseek_base_url": "https://api.deepseek.com",
  "default_backend": "deepseek",
  "force_model": "deepseek-chat"
}
```

OpenAI:

```json
{
  "openai_api_key": "REDACTED",
  "openai_base_url": "https://api.openai.com",
  "default_backend": "openai",
  "force_model": "gpt-4o"
}
```

Custom OpenAI-compatible provider:

```json
{
  "custom_api_key": "REDACTED",
  "custom_base_url": "https://provider.example.com",
  "default_backend": "custom",
  "force_model": "provider-model-name"
}
```

`custom_base_url` may be either `https://provider.example.com` or `https://provider.example.com/v1`.

## Verify

```bash
curl -sS http://127.0.0.1:9876/health
curl -sS http://127.0.0.1:9876/v1/models
curl -sS http://127.0.0.1:9876/v1/messages \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":32,"messages":[{"role":"user","content":"Reply OK"}]}'
```

Recent request log:

```bash
curl -sS http://127.0.0.1:9876/api/recent-requests
```

## Files

```text
.
├── AGENTS.md
├── README.md
├── SECURITY.md
├── config.example.json
├── proxy.py
├── setup-token.py
├── start.sh
├── install.sh
├── setup-network.sh
├── requirements.txt
├── scripts/
│   ├── doctor.sh
│   ├── install-safe.sh
│   ├── start-claude-science.sh
│   └── uninstall.sh
├── docs/
│   ├── agent-runbook.md
│   ├── github-publishing.md
│   ├── network-interception.md
│   └── troubleshooting.md
└── static/
    └── dashboard.html
```

## Do Not Commit

`.gitignore` excludes local secrets and generated state:

- `config.json`
- `.env`
- `certs/`
- `*.plist`
- logs
- Python caches

Before publishing:

```bash
git status --ignored
```

Confirm no API key, private key, OAuth token, or local certificate is staged.

## License

MIT. See `LICENSE`.
