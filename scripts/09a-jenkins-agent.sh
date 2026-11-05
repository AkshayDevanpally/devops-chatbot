#!/usr/bin/env bash
# Phase 4: the Jenkins build agent on this host, as a locked-down systemd service. Re-runnable.
# Runs as a dedicated system user "jenkins-agent" (no login, no sudo) in the docker group.
# NOTE: docker group access is root-equivalent on this host, so only build trusted code
# (the job only builds this repo's own branch).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
cd "$(dirname "$0")/.."

URL=https://jenkins.chatbot.local
AGENT_USER=jenkins-agent
HOME_DIR=/var/lib/jenkins-agent
ETC=/etc/jenkins-agent
CA=/usr/local/share/ca-certificates/qwenops-local-ca.crt
KUBECTL="kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"

[[ -s $CA ]] || { echo "local CA not trusted yet: run make trust-ca first"; exit 1; }

echo "==> Java 21 runtime (the agent is a Java program)"
command -v java >/dev/null || { apt-get update -q && apt-get install -y -q openjdk-21-jre-headless; }

echo "==> make Java trust the local CA"
CACERTS=$(readlink -f "$(dirname "$(readlink -f "$(command -v java)")")/../lib/security/cacerts")
if ! keytool -list -cacerts -storepass changeit -alias qwenops-local-ca >/dev/null 2>&1; then
  keytool -importcert -noprompt -cacerts -storepass changeit -alias qwenops-local-ca -file "$CA"
fi
echo "    $CACERTS"

echo "==> hosts entry for jenkins.chatbot.local"
grep -qE '^\s*127\.0\.0\.1\s.*\bjenkins\.chatbot\.local\b' /etc/hosts || echo "127.0.0.1 jenkins.chatbot.local" >> /etc/hosts

echo "==> system user $AGENT_USER"
id "$AGENT_USER" >/dev/null 2>&1 || useradd --system --home-dir "$HOME_DIR" --create-home --shell /usr/sbin/nologin "$AGENT_USER"
usermod -aG docker "$AGENT_USER"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0750 "$HOME_DIR"
install -d -o root -g "$AGENT_USER" -m 0750 "$ETC"

echo "==> kubeconfig limited to deploying the chatbot (ServiceAccount ci/jenkins-deployer)"
TOKEN=$($KUBECTL -n ci get secret jenkins-deployer-token -o jsonpath='{.data.token}' | base64 -d)
[[ -n $TOKEN ]] || { echo "deployer token missing: run make jenkins first"; exit 1; }
CA_DATA=$($KUBECTL config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
umask 027
cat > "$ETC/kubeconfig" <<KCFG
apiVersion: v1
kind: Config
clusters:
  - name: k3s
    cluster: { server: "https://127.0.0.1:6443", certificate-authority-data: "$CA_DATA" }
users:
  - name: jenkins-deployer
    user: { token: "$TOKEN" }
contexts:
  - name: deployer
    context: { cluster: k3s, user: jenkins-deployer, namespace: chatbot-dev }
current-context: deployer
KCFG
chown root:"$AGENT_USER" "$ETC/kubeconfig"; chmod 0640 "$ETC/kubeconfig"

echo "==> agent secret and agent.jar from the controller"
PW=$($KUBECTL -n ci get secret jenkins-secrets -o jsonpath='{.data.admin-password}' | base64 -d)
SECRET=$(curl -sf --cacert "$CA" -u "admin:$PW" "$URL/computer/host-agent/jenkins-agent.jnlp" \
  | grep -o '<argument>[0-9a-f]\{64\}</argument>' | head -1 | sed 's:</\?argument>::g')
[[ -n $SECRET ]] || { echo "could not read the agent secret from $URL (is Jenkins up?)"; exit 1; }
printf '%s' "$SECRET" > "$ETC/secret"; chown root:"$AGENT_USER" "$ETC/secret"; chmod 0640 "$ETC/secret"
curl -sf --cacert "$CA" -o "$ETC/agent.jar" "$URL/jnlpJars/agent.jar"
chmod 0644 "$ETC/agent.jar"                                  # root-owned: the agent can't replace it

echo "==> keep automatic updates from restarting the agent mid-build"
# Ubuntu's unattended-upgrades runs needrestart, which restarts every service using an updated
# library. That killed a running build once (docs/capacity-journal-issues.md, Issue 14). The agent
# still gets the update: restart it when no build is running (sudo systemctl restart jenkins-agent).
if [[ -d /etc/needrestart/conf.d ]]; then
  cat > /etc/needrestart/conf.d/50-jenkins-agent.conf <<'NR'
# Never auto-restart the Jenkins agent: it would kill the running build.
$nrconf{override_rc}{qr(^jenkins-agent\.service$)} = 0;
NR
fi

echo "==> systemd service"
cat > /etc/systemd/system/jenkins-agent.service <<UNIT
[Unit]
Description=Jenkins build agent (QwenOps)
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=$AGENT_USER
Group=$AGENT_USER
SupplementaryGroups=docker
Environment=KUBECONFIG=$ETC/kubeconfig
Environment=CA_FILE=$CA
WorkingDirectory=$HOME_DIR
ExecStart=/usr/bin/java -Xmx256m -jar $ETC/agent.jar -url $URL/ -name host-agent -secret @$ETC/secret -webSocket -workDir $HOME_DIR
Restart=always
RestartSec=10
# Hardening: read-only OS, no access to /home, no privilege gain, private /tmp.
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$HOME_DIR
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable jenkins-agent >/dev/null
systemctl restart jenkins-agent
sleep 8
systemctl --no-pager --lines=5 status jenkins-agent || true
echo "Agent installed. Check it shows as connected: $URL/computer/host-agent/"
