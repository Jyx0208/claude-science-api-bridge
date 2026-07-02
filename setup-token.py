#!/usr/bin/env python3
"""Create a fake OAuth token for Claude Science BYOK (Bring Your Own Key).

This creates an encrypted OAuth token that Claude Science will accept as valid,
allowing you to use third-party APIs through the local proxy.

Usage:
    python3 setup-token.py
"""

import base64
import json
import os
import re
import sys

from cryptography.fernet import Fernet

TOKEN_DIR = os.path.expanduser("~/.claude-science/.oauth-tokens")
ENC_KEY_FILE = os.path.expanduser("~/.claude-science/encryption.key")
CLAUDE_AI_SCOPES = "user:inference user:file_upload user:profile user:mcp_servers user:plugins"


def read_oauth_key():
    with open(ENC_KEY_FILE) as f:
        for line in f:
            if line.startswith("OAUTH_ENCRYPTION_KEY="):
                return line.strip().split("=", 1)[1]
    raise ValueError("OAUTH_ENCRYPTION_KEY not found in encryption.key")


def sanitize_user_id(uid: str) -> str:
    """Keep only alphanumeric, underscore, hyphen."""
    return re.sub(r"[^a-zA-Z0-9_-]", "", uid)


def encrypt_fernet(key: str, plaintext: str) -> str:
    """Encrypt using Fernet (matching eH.encryptToken format)."""
    f = Fernet(key.encode())
    return f.encrypt(plaintext.encode()).decode()


def main():
    account_uuid = "byok-user-000000000000000000"
    org_uuid = "org_byok_000000000000"
    fake_access_token = "fake-bearer-token-for-proxy"

    token_data = {
        "access_token": fake_access_token,
        "refresh_token": None,
        "api_key": None,
        "token_expires_at": "2099-12-31T23:59:59Z",
        # Claude Science's daemon only treats .oauth-tokens as signed in when
        # the provider is exactly "claude_ai".
        "provider": "claude_ai",
        "scopes": CLAUDE_AI_SCOPES,
        "email": "byok@localhost",
        "account_uuid": account_uuid,
        "subscription_type": "max",
        "rate_limit_tier": "tier_5",
        "seat_tier": "enterprise_usage_based",
        "org_uuid": org_uuid,
        "organization": {
            "uuid": org_uuid,
            "name": "BYOK Organization",
            "organization_type": "claude_max",
            "rate_limit_tier": "tier_5",
            "seat_tier": "enterprise_usage_based",
            "billing_type": "api",
            "has_extra_usage_enabled": True,
            "claude_ai_completion_feedback_enabled": False,
        },
        "billing_type": "api",
        "has_extra_usage_enabled": True,
    }

    oauth_key = read_oauth_key()

    # Encrypt with Fernet
    plaintext = json.dumps(token_data)
    try:
        encrypted = encrypt_fernet(oauth_key, plaintext)
        print("Encrypted OAuth token successfully")
    except Exception as e:
        print(f"Fernet encryption failed: {e}")
        sys.exit(1)

    os.makedirs(TOKEN_DIR, mode=0o700, exist_ok=True)
    safe_id = sanitize_user_id(account_uuid)
    token_path = os.path.join(TOKEN_DIR, f"{safe_id}.enc")

    with open(token_path, "w") as f:
        f.write(encrypted)
    os.chmod(token_path, 0o600)

    print(f"Token written to: {token_path}")

    # Verify: read the file back and try to decrypt
    with open(token_path) as f:
        read_back = f.read()
    try:
        f2 = Fernet(oauth_key.encode())
        decrypted = json.loads(f2.decrypt(read_back.encode()))
        print(f"Verified: token decrypts correctly for account {decrypted['account_uuid']}")
    except Exception as e:
        print(f"Verification failed: {e}")
        sys.exit(1)

    print("\nDone! Next step: start the proxy with start.sh")


if __name__ == "__main__":
    main()
