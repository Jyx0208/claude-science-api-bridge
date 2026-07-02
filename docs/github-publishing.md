# GitHub Publishing Guide

Run from the repository root:

```bash
cd ~/.claude-science/proxy
./scripts/self-test.sh
git init -b main
git status --ignored
```

Confirm these are ignored and not staged:

- `config.json`
- `.env`
- `certs/`
- `*.plist`
- `__pycache__/`
- logs

Then:

```bash
git add .
git status
git commit -m "Initial open-source release"
```

Create a GitHub repository, then:

```bash
git remote add origin git@github.com:YOUR_NAME/claude-science-third-party-api-proxy.git
git push -u origin main
```

If using HTTPS instead of SSH:

```bash
git remote add origin https://github.com/YOUR_NAME/claude-science-third-party-api-proxy.git
git push -u origin main
```

Before every push:

```bash
./scripts/self-test.sh
git diff --cached
git status --ignored
```

If this machine has a backend API key configured and you are validating a real installation, also run:

```bash
./scripts/verify-proxy.sh
```

Never paste API keys or token contents into GitHub issues.
