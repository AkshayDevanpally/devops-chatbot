#!/usr/bin/env bash
# Installs a hardened single-node k3s + Helm on Ubuntu Server. Run once with sudo.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
K3S_VERSION="${K3S_VERSION:-}"   # e.g. v1.33.5+k3s1 to pin; empty = current stable channel

echo "==> kernel settings required by --protect-kernel-defaults"
cat >/etc/sysctl.d/90-kubelet.conf <<'EOF'
vm.panic_on_oom=0
vm.overcommit_memory=1
kernel.panic=10
kernel.panic_on_oops=1
EOF
sysctl --system >/dev/null

echo "==> 4 GB swap as a safety net for an 8 GB host"
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> audit policy (who did what to the API)"
mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/server/logs
cat >/etc/rancher/k3s/audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: [RequestReceived]
rules:
  - level: None
    resources: [{ group: "", resources: [events] }]
  - level: Metadata
    resources: [{ group: "", resources: [secrets, configmaps] }]
  - level: RequestResponse
    verbs: [create, update, patch, delete]
  - level: Metadata
EOF

echo "==> allow k3s to pull from the local registry (plain HTTP, localhost only)"
cat >/etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
EOF

echo "==> k3s config"
cat >/etc/rancher/k3s/config.yaml <<'EOF'
write-kubeconfig-mode: "0600"
secrets-encryption: true
protect-kernel-defaults: true
kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log"
  - "audit-policy-file=/etc/rancher/k3s/audit-policy.yaml"
  - "audit-log-maxage=7"
  - "audit-log-maxbackup=3"
  - "audit-log-maxsize=50"
kubelet-arg:
  - "max-pods=60"
  - "system-reserved=cpu=500m,memory=768Mi"
  - "kube-reserved=cpu=250m,memory=512Mi"
  - "eviction-hard=memory.available<300Mi"
EOF

echo "==> install k3s (Traefik ingress + metrics-server + local-path storage + network policies are built in)"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -

echo "==> AppArmor profile for the chatbot pods"
"$(dirname "$0")/01a-apparmor.sh"

echo "==> kubeconfig for your user"
SUDO_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
mkdir -p "$SUDO_HOME/.kube"
cp /etc/rancher/k3s/k3s.yaml "$SUDO_HOME/.kube/config"
chown -R "${SUDO_USER:-root}": "$SUDO_HOME/.kube" && chmod 600 "$SUDO_HOME/.kube/config"

echo "==> Helm"
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "==> waiting for the node"
k3s kubectl wait --for=condition=Ready node --all --timeout=180s
k3s kubectl get nodes -o wide
echo "Done. Next: ./scripts/02-local-registry.sh"
