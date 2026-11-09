#!/usr/bin/env bash
# Install the home CA on a phone or laptop: serves only the public certificate on the LAN for 10 minutes.
#
#   sudo ./scripts/16-lan-access.sh share-ca
#
# The names (chatbot.local & co.) are announced by the Raspberry Pi gateway (pi/, make pi-gateway), not
# by this server: announcing them here too would clash. (An earlier version of this script did that.)
set -euo pipefail
cd "$(dirname "$0")/.."
IFACE=$(ip -4 route show default | awk '{print $5; exit}')
LAN_IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
LAN_NET=$(ip -4 route show dev "$IFACE" scope link proto kernel | awk '{print $1; exit}')
need_root() { [[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }; }

share_ca() {
  need_root
  ca=certs/chatbot-local-ca.crt
  [[ -s $ca ]] || { echo "no $ca: run 'make tls' first"; exit 1; }
  dir=$(mktemp -d); cp "$ca" "$dir/qwenops-ca.crt"; chmod 755 "$dir"; chmod 644 "$dir/qwenops-ca.crt"
  port=8099
  ufw status | grep -q "Status: active" && ufw allow from "$LAN_NET" to any port $port proto tcp comment 'qwenops: CA download (temporary)' >/dev/null
  cleanup() { ufw status | grep -q "Status: active" && ufw delete allow from "$LAN_NET" to any port $port proto tcp >/dev/null 2>&1; rm -rf "$dir"; }
  trap cleanup EXIT
  echo "SHA-256 fingerprint (compare on the phone if it shows one):"
  openssl x509 -in "$ca" -noout -fingerprint -sha256 | cut -d= -f2
  cat <<MSG

On the phone (same Wi-Fi), open:  http://$LAN_IP:$port/qwenops-ca.crt
  Android: it downloads; then Settings > Security & privacy > More security settings >
           Encryption & credentials > Install a certificate > CA certificate > pick qwenops-ca.crt
           (menu names vary by brand; search Settings for "CA certificate").
  iPhone:  open it in Safari > Allow > Settings > Profile Downloaded > Install; then
           Settings > General > About > Certificate Trust Settings > turn on "QwenOps Local CA".
  Firefox on Android also needs: Settings > About Firefox > tap the logo 5x > Secret settings >
           "Use third party CA certificates".
Serving for 10 minutes (Ctrl+C to stop sooner). Only the public certificate is served.
MSG
  # Plain HTTP on purpose: the phone doesn't trust the CA yet. The file is public; check the fingerprint.
  timeout 600 python3 -I -m http.server "$port" --bind "$LAN_IP" --directory "$dir" || true
}

case "${1:-}" in
  share-ca) share_ca ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
