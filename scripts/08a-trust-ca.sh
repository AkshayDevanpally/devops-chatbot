#!/usr/bin/env bash
# Adds the local CA to this machine's trust store (curl, Python, Chrome via the system store).
# Firefox keeps its own store: import certs/chatbot-local-ca.crt under Settings > Certificates.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
cd "$(dirname "$0")/.."

CA=certs/chatbot-local-ca.crt
[[ -s $CA ]] || { echo "$CA missing: run make tls first"; exit 1; }
install -m 0644 "$CA" /usr/local/share/ca-certificates/qwenops-local-ca.crt
update-ca-certificates
echo "Trusted. Test: curl https://dev.chatbot.local/api/healthz"
