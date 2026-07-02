# Agent Runbook

This is the main step-by-step guide for an AI agent configuring this project on a user's Mac.

## Phase 0: Safety Check

Run only read-only checks first:

```bash
./scripts/doctor.sh
```

Inspect:

- macOS version
- Python path and version
- whether Claude Science is installed
- whether `~/.claude-science/encryption.key` exists
- whether `ANTHROPIC_BASE_URL` is already set
- whether ports `9876`, `9877`, `443`, and `8765` are in use
- whether the proxy is already healthy

Do not change Clash or any network proxy tool.

## Phase 1: Install Safe Mode

Safe mode does not modify `/etc/hosts`, certificates, Clash, DNS, TUN, VPN, or port 443.

```bash
./scripts/install-safe.sh
```

This should:

1. Install Python dependencies.
2. Create `config.json` from `config.example.json` if missing.
3. Generate a fake OAuth token with `setup-token.py`.
4. Set `ANTHROPIC_BASE_URL=http://127.0.0.1:9876` via `launchctl`.
5. Install and start a user LaunchAgent for `proxy.py`.

The script prefers a project-local `.venv` so it does not depend on global Python packages.
If `~/.claude-science/encryption.key` does not exist yet, it may open Claude Science once so the app can create local state.

## Phase 2: Configure Provider

Prefer the dashboard:

```bash
open http://127.0.0.1:9876/dashboard
```

For unattended setup, write `config.json` directly. Never echo secrets into chat logs.
`scripts/install-safe.sh` also accepts provider settings from environment variables and persists them into ignored `config.json`.

Minimum DeepSeek config:

```json
{
  "deepseek_api_key": "REDACTED",
  "deepseek_base_url": "https://api.deepseek.com",
  "default_backend": "deepseek",
  "force_model": "deepseek-chat"
}
```

Generic OpenAI-compatible provider:

```json
{
  "custom_api_key": "REDACTED",
  "custom_base_url": "https://provider.example.com",
  "default_backend": "custom",
  "force_model": "provider-model-name",
  "inline_image_policy": "auto"
}
```

If the provider base URL already includes `/v1`, keep it; the proxy normalizes both forms.

For SiliconFlow Kimi:

```json
{
  "custom_api_key": "REDACTED",
  "custom_base_url": "https://api.siliconflow.cn",
  "default_backend": "custom",
  "force_model": "Pro/moonshotai/Kimi-K2.6",
  "inline_image_policy": "preserve",
  "reasoning_content_policy": "never"
}
```

Use `inline_image_policy=preserve` only when the selected model supports image input. Use `omit` for text-only models.
Keep `reasoning_content_policy=never` unless the user explicitly asks to debug provider reasoning payloads.

## Phase 3: Verify Proxy

Run:

```bash
./scripts/self-test.sh
./scripts/verify-proxy.sh
curl -sS http://127.0.0.1:9876/health
curl -sS http://127.0.0.1:9876/v1/models
curl -sS http://127.0.0.1:9876/v1/messages \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-sonnet-4-5","max_tokens":32,"messages":[{"role":"user","content":"Reply OK"}]}'
```

Expected:

- `/health` returns `"status":"ok"`.
- `/v1/models` returns model objects.
- `/v1/messages` returns an Anthropic-style message object.
- `/api/recent-requests` shows backend `success`.
- `./scripts/verify-proxy.sh` exits with `proxy verification passed`.

If the user asked for image understanding and the selected model is vision-capable, run:

```bash
VERIFY_IMAGE=1 ./scripts/verify-proxy.sh
```

Expected:

- The script generates a red PNG.
- The proxy converts Anthropic image input into OpenAI-compatible image input.
- The backend response confirms `red`.

Do not report image support as working until this test passes.

## Phase 4: Start Claude Science

If the app is not running:

```bash
open -a "Claude Science"
```

If it is already running, restart it:

```bash
pkill -f "claude-science serve" 2>/dev/null || true
pkill -f "ClaudeScience" 2>/dev/null || true
open -a "Claude Science"
```

Verify the daemon:

```bash
lsof -nP -iTCP:8765 -sTCP:LISTEN
curl -sS http://127.0.0.1:9876/api/recent-requests
```

Expected requests include `GET /v1/models` and `POST /v1/messages`.

## Phase 5: If Auth/Profile Fails

First confirm safe-mode requests are working. Many Claude Science model calls use `ANTHROPIC_BASE_URL` and do not require HTTPS interception.

If the app still reports the session is invalid:

1. Run `./scripts/doctor.sh`.
2. Check whether `/api/oauth/profile`, `/api/oauth/account`, or `/v1/oauth/*` hit the proxy.
3. Regenerate token:

```bash
python3 setup-token.py
```

4. Restart Claude Science.

Only consider `docs/network-interception.md` if the daemon uses hard-coded Anthropic URLs that bypass `ANTHROPIC_BASE_URL`.

## Phase 6: Cleanup

To remove safe-mode installation:

```bash
./scripts/uninstall.sh
```

This removes the user LaunchAgent and launchctl environment variables. It does not delete API keys unless the user asks.

## Phase 7: Before Publishing

Run:

```bash
./scripts/self-test.sh
git status --ignored
```

Confirm ignored local files are not staged:

- `config.json`
- `.env`
- `certs/`
- `*.plist`
- logs
- Python caches
