#!/usr/bin/env bash
# Loads the k8s-chatbot AppArmor profile on this node (pods reference it as Localhost/k8s-chatbot).
# Persists across reboots via /etc/apparmor.d. Run with sudo; safe to re-run.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
cd "$(dirname "$0")/.."

install -m 0644 k8s/apparmor/k8s-chatbot /etc/apparmor.d/k8s-chatbot
apparmor_parser -r -W /etc/apparmor.d/k8s-chatbot
grep -q '^k8s-chatbot ' /sys/kernel/security/apparmor/profiles && echo "==> AppArmor profile k8s-chatbot loaded"
