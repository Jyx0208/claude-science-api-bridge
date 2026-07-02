# Advanced HTTPS Interception

This mode is optional and risky. Use it only when Claude Science makes hard-coded HTTPS requests that ignore `ANTHROPIC_BASE_URL`.

Do not run this automatically.

## What It Does

Advanced mode may use:

- `/etc/hosts` entries for Anthropic domains.
- a local self-signed CA and server certificate.
- an HTTPS proxy on `127.0.0.1:9877`.
- a root TCP forwarder from `127.0.0.1:443` to `127.0.0.1:9877`.

## What It Must Not Do By Default

- Do not edit Clash configuration.
- Do not reload Clash or its kernel.
- Do not change VPN, DNS, system proxy, or TUN settings.

Users who run Clash fake-ip mode should configure their network tool manually. The agent should provide instructions, not mutate those files.

## Safer Verification Without Changing DNS

Use `curl --resolve`:

```bash
curl -sk --resolve api.anthropic.com:443:127.0.0.1 \
  https://api.anthropic.com:443/health
```

If this works, the local HTTPS proxy is healthy. DNS/routing remains a separate user-controlled step.

## When to Stop

If the user says internet access was affected, immediately stop changing network settings. Continue only with safe-mode HTTP proxy changes.

