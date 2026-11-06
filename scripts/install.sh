#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_DIR="/usr/local/etc/xray"
CONFIG="${XRAY_DIR}/config.json"
LINK_FILE="/root/napsternet-vpn-client.txt"
SERVICE="xray"
SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
PORT="${VLESS_PORT:-443}"

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || fail "Run as root: sudo bash scripts/install.sh"
[[ -r /etc/os-release ]] || fail "Cannot identify Linux distribution."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "This installer supports Ubuntu 22.04/24.04 only."
[[ "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" ]] || fail "Use Ubuntu 22.04 or 24.04."
[[ "${PORT}" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || fail "Invalid VLESS_PORT."
[[ "${SERVER_NAME}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Invalid REALITY_SERVER_NAME."

if [[ -f "${CONFIG}" ]]; then
  fail "Existing ${CONFIG} found. Back it up/remove it deliberately before reinstalling."
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl unzip openssl uuid-runtime qrencode

# Install Xray using the official XTLS installer.
tmp_installer="$(mktemp)"
trap 'rm -f "$tmp_installer"' EXIT
curl -fsSL --retry 3 https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp_installer"
bash "$tmp_installer" install

XRAY_BIN="$(command -v xray || true)"
[[ -x "${XRAY_BIN}" ]] || [[ -x /usr/local/bin/xray ]] || fail "Xray binary was not installed."
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"

# Generate server/client credentials locally on this VPS.
UUID="$(uuidgen)"
SHORT_ID="$(openssl rand -hex 8)"
KEY_OUTPUT="$("${XRAY_BIN}" x25519 2>&1)" || fail "Could not generate REALITY keys: ${KEY_OUTPUT}"

# Xray versions have used different labels. Prefer PrivateKey + Password (the
# REALITY public key in current Xray output), then fall back to Private/Public key.
PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" | sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' | head -n1)"
PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" | sed -nE 's/^[[:space:]]*Password:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' | head -n1)"
if [[ -z "$PRIVATE_KEY" ]]; then
  PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" | sed -nE 's/^[[:space:]]*Private key:[[:space:]]*([A-Za-z0-9_-]+).*/\1/ip' | head -n1)"
fi
if [[ -z "$PUBLIC_KEY" ]]; then
  PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" | sed -nE 's/^[[:space:]]*Public key:[[:space:]]*([A-Za-z0-9_-]+).*/\1/ip' | head -n1)"
fi
[[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || fail "Could not parse REALITY key output. Xray output was: ${KEY_OUTPUT}"

SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
[[ -n "$SERVER_IP" ]] || fail "Could not detect public IPv4. Set up public IPv4 and rerun."

install -d -m 0755 "${XRAY_DIR}"
cat > "${CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SERVER_NAME}:443",
          "xver": 0,
          "serverNames": [
            "${SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
chmod 600 "${CONFIG}"

# Validate config before enabling the service.
"${XRAY_BIN}" run -test -config "${CONFIG}"

# Ensure systemd unit exists (official installer normally creates it).
systemctl daemon-reload
systemctl enable --now "${SERVICE}"
systemctl restart "${SERVICE}"
sleep 2
systemctl is-active --quiet "${SERVICE}" || {
  journalctl -u "${SERVICE}" -n 80 --no-pager >&2 || true
  fail "Xray service did not start."
}

# Open TCP port. UFW is only enabled if it was already active; this avoids
# unexpectedly changing a server's firewall policy.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp"
fi

ENC_SERVER="$(printf '%s' "$SERVER_NAME" | sed 's/:/%3A/g')"
LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${ENC_SERVER}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#NPV-VLESS-REALITY"

umask 077
printf '%s\n' "$LINK" > "${LINK_FILE}"
chmod 600 "${LINK_FILE}"

echo
echo "============================================================"
echo "Xray is running. Keep the following VLESS link private:"
echo "$LINK"
echo "============================================================"
echo "Saved securely to: ${LINK_FILE}"
if command -v qrencode >/dev/null 2>&1; then
  echo
  qrencode -t ANSIUTF8 "$LINK" || true
fi
echo
echo "Check status: systemctl status xray"
echo "Logs: journalctl -u xray -n 100 --no-pager"
echo "IMPORTANT: Open TCP/${PORT} in your VPS provider firewall/security group."
echo "Confirm your NapsternetV version supports VLESS + REALITY + Vision."
