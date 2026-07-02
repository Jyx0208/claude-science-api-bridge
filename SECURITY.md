# Security Policy

## Local Secrets

Never commit:

- `config.json`
- `.env`
- `certs/`
- OAuth token files under `~/.claude-science/.oauth-tokens/`
- `~/.claude-science/encryption.key`
- logs that may contain backend error text

## Network Safety

The default installation must not modify system DNS, Clash, VPN, TUN, or `/etc/hosts`.

Advanced HTTPS interception is opt-in and should be clearly explained before use.

## Reporting Issues

When filing issues, redact API keys, tokens, private keys, and prompt content.

