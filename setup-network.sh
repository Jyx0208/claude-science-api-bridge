#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-}"

cat <<'TEXT'
Advanced HTTPS interception is optional.

This script intentionally does not edit Clash, VPN, DNS client, TUN, or system
proxy configuration. It only manages local certificate files, optional
/etc/hosts entries, and the optional localhost 443 forwarder.

Use the safe install first:
  ./install.sh

Read:
  docs/network-interception.md
TEXT

if [ "$ACTION" = "--help" ] || [ -z "$ACTION" ]; then
  cat <<'TEXT'

Commands:
  ./setup-network.sh certs        Generate local CA/server certificate files
  ./setup-network.sh trust-ca     Trust the generated CA in the macOS System keychain
  ./setup-network.sh hosts        Add Anthropic host entries to /etc/hosts
  ./setup-network.sh forwarder    Install root LaunchDaemon for 127.0.0.1:443 -> 127.0.0.1:9877
  ./setup-network.sh verify       Verify local HTTPS proxy with curl --resolve
  ./setup-network.sh uninstall    Remove hosts entries, CA trust, and forwarder

Run each command explicitly. Do not run advanced mode unless the user approves.
TEXT
  exit 0
fi

run_sudo() {
  osascript -e "do shell script \"$1\" with administrator privileges"
}

case "$ACTION" in
  certs)
    mkdir -p "$SCRIPT_DIR/certs"
    if [ ! -f "$SCRIPT_DIR/certs/ca-key.pem" ]; then
      openssl genrsa -out "$SCRIPT_DIR/certs/ca-key.pem" 2048
      openssl req -x509 -new -nodes -key "$SCRIPT_DIR/certs/ca-key.pem" \
        -sha256 -days 3650 -out "$SCRIPT_DIR/certs/ca-cert.pem" \
        -subj "/CN=Claude Science Proxy Local CA"
    fi
    cat > "$SCRIPT_DIR/certs/server.cnf" <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = api.anthropic.com

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = api.anthropic.com
DNS.2 = auth.anthropic.com
DNS.3 = console.anthropic.com
DNS.4 = anthropic.com
DNS.5 = platform.claude.com
DNS.6 = claude.com
DNS.7 = claude.ai
DNS.8 = *.anthropic.com
DNS.9 = *.claude.com
DNS.10 = *.claude.ai
EOF
    openssl genrsa -out "$SCRIPT_DIR/certs/server-key.pem" 2048
    openssl req -new -key "$SCRIPT_DIR/certs/server-key.pem" \
      -out "$SCRIPT_DIR/certs/server.csr" -config "$SCRIPT_DIR/certs/server.cnf"
    openssl x509 -req -in "$SCRIPT_DIR/certs/server.csr" \
      -CA "$SCRIPT_DIR/certs/ca-cert.pem" -CAkey "$SCRIPT_DIR/certs/ca-key.pem" \
      -CAcreateserial -out "$SCRIPT_DIR/certs/server-cert.pem" -days 3650 \
      -extensions v3_req -extfile "$SCRIPT_DIR/certs/server.cnf"
    chmod 600 "$SCRIPT_DIR/certs/"*-key.pem
    echo "Generated certs in $SCRIPT_DIR/certs"
    ;;

  trust-ca)
    test -f "$SCRIPT_DIR/certs/ca-cert.pem" || {
      echo "Missing certs/ca-cert.pem. Run ./setup-network.sh certs first."
      exit 1
    }
    run_sudo "security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '$SCRIPT_DIR/certs/ca-cert.pem'"
    echo "Trusted local CA."
    ;;

  hosts)
    run_sudo "cp /etc/hosts /etc/hosts.claude-science-proxy.bak 2>/dev/null || true; sed -i '' '/# claude-science-proxy/d;/anthropic\\.com/d;/platform\\.claude\\.com/d' /etc/hosts; printf '\\n127.0.0.1 api.anthropic.com auth.anthropic.com console.anthropic.com anthropic.com platform.claude.com # claude-science-proxy\\n' >> /etc/hosts"
    echo "Updated /etc/hosts. No Clash settings were changed."
    ;;

  forwarder)
    PYTHON_BIN="${PYTHON:-$(command -v python3)}"
    mkdir -p "$HOME/.claude-science/logs"
    run_sudo "cat > /Library/LaunchDaemons/com.byok.proxy-forwarder.plist <<'PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>com.byok.proxy-forwarder</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON_BIN</string>
        <string>$SCRIPT_DIR/forward-443.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>UserName</key>
    <string>root</string>
    <key>StandardOutPath</key>
    <string>$HOME/.claude-science/logs/forwarder.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude-science/logs/forwarder-error.log</string>
</dict>
</plist>
PLIST
launchctl unload /Library/LaunchDaemons/com.byok.proxy-forwarder.plist 2>/dev/null || true
launchctl load /Library/LaunchDaemons/com.byok.proxy-forwarder.plist"
    echo "Installed 443 forwarder LaunchDaemon."
    ;;

  verify)
    curl -sk --resolve api.anthropic.com:443:127.0.0.1 \
      https://api.anthropic.com:443/health
    printf '\n'
    ;;

  uninstall)
    run_sudo "sed -i '' '/claude-science-proxy/d;/anthropic\\.com/d;/platform\\.claude\\.com/d' /etc/hosts 2>/dev/null || true; launchctl unload /Library/LaunchDaemons/com.byok.proxy-forwarder.plist 2>/dev/null || true; rm -f /Library/LaunchDaemons/com.byok.proxy-forwarder.plist; security delete-certificate -c 'Claude Science Proxy Local CA' /Library/Keychains/System.keychain 2>/dev/null || true"
    echo "Removed advanced HTTPS interception pieces. Clash was not changed."
    ;;

  *)
    echo "Unknown command: $ACTION"
    exit 1
    ;;
esac

