#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${EUID}" -eq 0 ]] || { echo "Run as root: sudo bash scripts/uninstall.sh" >&2; exit 1; }
read -r -p "This removes Xray and its config/client link. Continue? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || exit 0
systemctl disable --now xray 2>/dev/null || true
rm -rf /usr/local/etc/xray
rm -f /root/napsternet-vpn-client.txt
if [[ -f /usr/local/bin/xray ]]; then
  rm -f /usr/local/bin/xray
fi
echo "Xray service and this project's files have been removed."
echo "The Xray installer may have installed additional files; inspect /usr/local/share/xray if desired."
