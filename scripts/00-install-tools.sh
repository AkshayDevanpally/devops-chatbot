#!/usr/bin/env bash
# Installs every tool this project needs on a fresh Ubuntu Server 22.04 / 24.04.
# Run as your normal user (NOT with sudo) - it calls sudo itself, so your user gets added to the docker group:
#   chmod +x scripts/00-install-tools.sh && ./scripts/00-install-tools.sh
# Safe to re-run.
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo "run as your normal user, not root/sudo"; exit 1; }

ARCH=$(dpkg --print-architecture)   # amd64 or arm64

echo "==> 1. Base packages (git, make, curl, openssl, python3, jq ...)"
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y \
  ca-certificates curl wget gnupg lsb-release apt-transport-https \
  git make openssl python3 jq unzip

echo "==> 2. Docker Engine + buildx + compose plugin (official Docker repo)"
# Remove Ubuntu's own (older) Docker packages if present
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"     # run docker without sudo (takes effect after you log out and back in)

echo "==> 3. Trivy - image vulnerability scanner (used by 'make build')"
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list >/dev/null
sudo apt-get update
sudo apt-get install -y trivy

echo "==> 4. hadolint - Dockerfile linter (used by 'make build')"
case $ARCH in amd64) HA=x86_64 ;; arm64) HA=arm64 ;; *) echo "unsupported arch $ARCH"; exit 1 ;; esac
sudo curl -fsSL -o /usr/local/bin/hadolint \
  "https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-$HA"
sudo chmod +x /usr/local/bin/hadolint

echo
echo "==> Installed versions"
git --version
make --version | head -1
python3 --version
openssl version
docker --version
docker compose version
docker buildx version
trivy --version | head -1
hadolint --version

cat <<'EOF'

Done. Next steps:
  1. Log out and back in (or run: newgrp docker) so 'docker' works without sudo.
  2. cd into the project and run:
       make test        # tests (uses Docker)
       make k3s         # installs hardened k3s + kubectl + Helm (asks for sudo)
       make registry    # local image registry on localhost:5000
       make platform
       ...see README.md for the rest.
  k3s, kubectl and Helm are installed by 'make k3s' on purpose: that script writes the
  security config BEFORE k3s starts, so don't install k3s any other way first.
EOF
