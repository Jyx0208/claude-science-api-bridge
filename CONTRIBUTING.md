# Contributing

## Development Setup

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
./scripts/self-test.sh
./scripts/doctor.sh
```

## Safety Rules

- Keep safe mode as the default path.
- Do not add scripts that silently modify Clash, VPN, TUN, DNS, or system proxy settings.
- Do not log request bodies by default.
- Do not commit generated certificates or API keys.
- Put advanced network interception behind explicit commands.

## Pull Request Checklist

- `./scripts/self-test.sh` passes.
- If a backend API key is configured on the machine, `./scripts/verify-proxy.sh` passes.
- Optional: `python3 -m pytest -q` passes.
- README and `AGENTS.md` still match behavior.
- No secrets are staged.
