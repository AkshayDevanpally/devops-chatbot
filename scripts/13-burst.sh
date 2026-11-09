#!/usr/bin/env bash
# Phase 6: burst compute in AWS. One Spot machine joins the home k3s cluster as a worker over the
# WireGuard tunnel and runs extra prod chat-api pods with their own Ollama.
#
#   sudo ./scripts/13-burst.sh prepare   # once: firewall rules on wg0 for the burst node
#   ./scripts/13-burst.sh up             # AWS node (Terraform) + home wg0, then join and deploy
#   ./scripts/13-burst.sh test           # checks
#   ./scripts/13-burst.sh down           # burst pods off, node removed, wg0 down, terraform destroy
#   ./scripts/13-burst.sh status
#
# The node terminates itself after 30 idle minutes or 6 hours; run `down` afterwards to tidy up.
# Needs `make db-tls`. Keys: ~/.config/qwenops-tunnel (home key shared with the tunnel test).
set -euo pipefail
cd "$(dirname "$0")/.."

export AWS_PROFILE="${AWS_PROFILE:-chatbot}"
TF="terraform -chdir=terraform/burst"
DIR="${XDG_CONFIG_HOME:-$HOME/.config}/qwenops-tunnel"
WG_CONF=/etc/wireguard/wg0.conf
NODE=qwenops-burst
HOME_NODE=$(kubectl get nodes -l '!qwenops.io/burst' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

root() {  # run as root if sudo works without a prompt, otherwise print the command
  if sudo -n true 2>/dev/null; then sudo "$@"; else echo "    needs root, run:  sudo $*"; NEED_ROOT=1; fi
}
tf_out() { $TF output -raw "$1" 2>/dev/null || true; }
wg_up() { ip link show wg0 >/dev/null 2>&1; }

prepare() {
  [[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
  if ufw status | grep -q "Status: active"; then
    # Only from the burst node's tunnel address, only on wg0.
    ufw allow in on wg0 from 10.200.0.2 to any port 6443 proto tcp comment 'qwenops burst: k3s API'
    ufw allow in on wg0 from 10.200.0.2 to any port 8472 proto udp comment 'qwenops burst: flannel VXLAN'
    ufw allow in on wg0 from 10.200.0.2 to any port 5000 proto tcp comment 'qwenops burst: registry (read-only)'
    ufw status | grep -i qwenops
  else
    echo "ufw is not active: nothing to open"
  fi
}

up() {
  kubectl -n data get secret postgres-tls >/dev/null 2>&1 || { echo "run 'make db-tls' first"; exit 1; }
  if [ -n "$(terraform -chdir=terraform/tunnel state list 2>/dev/null)" ]; then
    echo "the Phase 5 tunnel test is still up (same tunnel addresses): run 'make tunnel-down' first"; exit 1
  fi
  mkdir -p "$DIR"; chmod 700 "$DIR"

  echo "==> cluster side: priority class, burst quotas, Prometheus cloud label"
  kubectl apply -f k8s/platform/10-quotas.yaml >/dev/null
  if ! kubectl diff -f k8s/platform/50-prometheus.yaml >/dev/null 2>&1; then
    kubectl apply -f k8s/platform/50-prometheus.yaml >/dev/null
    kubectl -n monitoring rollout restart deployment/prometheus >/dev/null
  fi
  # A node left over from a run that ended on its own (idle/max-lifetime/Spot) would block the join.
  kubectl delete node "$NODE" --ignore-not-found >/dev/null
  kubectl -n kube-system delete secret "$NODE.node-password.k3s" --ignore-not-found >/dev/null

  echo "==> keys and a one-hour join token"
  umask 077
  [ -s "$DIR/home.key" ] || wg genkey > "$DIR/home.key"
  wg pubkey < "$DIR/home.key" > "$DIR/home.pub"
  wg genkey > "$DIR/burst.key"; wg pubkey < "$DIR/burst.key" > "$DIR/burst.pub"
  id=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)
  secret=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 16)
  kubectl -n kube-system create secret generic "bootstrap-token-$id" --type bootstrap.kubernetes.io/token \
    --from-literal=token-id="$id" --from-literal=token-secret="$secret" \
    --from-literal=expiration="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
    --from-literal=usage-bootstrap-authentication=true --from-literal=usage-bootstrap-signing=true \
    --from-literal=auth-extra-groups=system:bootstrappers:k3s:default-node-token \
    --from-literal=description="QwenOps burst node join" >/dev/null
  kubectl -n kube-system label secret "bootstrap-token-$id" qwenops.io/burst=true >/dev/null
  ca_hash=$(curl -fsSk https://127.0.0.1:6443/cacerts | sha256sum | cut -d' ' -f1)
  umask 022

  home_ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
  lan_ip=$(kubectl get node "$HOME_NODE" -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}')
  k3s_version=$(kubectl get node "$HOME_NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
  echo "    home public IP $home_ip, home node $HOME_NODE at $lan_ip, k3s $k3s_version"

  echo "==> AWS node (Terraform)"
  $TF init -input=false >/dev/null
  TF_VAR_home_cidr="$home_ip/32" TF_VAR_home_lan_ip="$lan_ip" \
  TF_VAR_home_public_key="$(cat "$DIR/home.pub")" TF_VAR_aws_private_key="$(cat "$DIR/burst.key")" \
  TF_VAR_k3s_token="K10$ca_hash::$id.$secret" TF_VAR_k3s_version="$k3s_version" \
  TF_VAR_apparmor_profile="$(cat k8s/apparmor/k8s-chatbot)" \
    $TF apply -input=false -auto-approve
  ip=$(tf_out public_ip)

  echo "==> home wg0 config -> $DIR/wg0.conf"
  ( umask 077; cat > "$DIR/wg0.conf" <<CONF
# QwenOps burst tunnel, home end. Written by scripts/13-burst.sh; replaced on every 'up'.
[Interface]
Address = 10.200.0.1/24
PrivateKey = $(cat "$DIR/home.key")
# Read-only copy of the image registry, only on the tunnel address, only while the tunnel is up.
PostUp = docker run -d --rm --name registry-tunnel -p 10.200.0.1:5000:5000 -v registry-data:/var/lib/registry:ro -v $PWD/k8s/burst/registry-readonly.yml:/etc/docker/registry/config.yml:ro --security-opt no-new-privileges:true registry:2
PreDown = docker rm -f registry-tunnel

[Peer]
# AWS burst node $(tf_out instance_id) ($(tf_out market))
PublicKey = $(cat "$DIR/burst.pub")
Endpoint = $ip:51820
AllowedIPs = 10.200.0.2/32
PersistentKeepalive = 25
CONF
  )
  NEED_ROOT=0
  if wg_up; then root wg-quick down wg0; fi
  root install -m 600 -o root -g root "$DIR/wg0.conf" "$WG_CONF"
  root wg-quick up wg0
  if [ "$NEED_ROOT" = 1 ]; then
    echo; echo "Run the sudo lines above, then: make burst-ready"
    exit 0
  fi
  ready
}

ready() {
  wg_up || { echo "wg0 is not up: run the sudo lines from 'up' first"; exit 1; }
  echo "==> waiting for the AWS node to join (first boot installs k3s: a few minutes)"
  for i in $(seq 90); do
    kubectl get node "$NODE" >/dev/null 2>&1 && break
    [ "$i" -lt 90 ] || { echo "node never joined: see 'make burst-status'"; exit 1; }; sleep 10
  done
  kubectl wait node/"$NODE" --for=condition=Ready --timeout=300s

  echo "==> Ollama on the AWS node (downloads the image and the model)"
  kubectl -n data get secret postgres-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/postgres-ca.$$
  kubectl -n chatbot-prod create configmap postgres-ca --from-file=ca.crt=/tmp/postgres-ca.$$ \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f /tmp/postgres-ca.$$
  kubectl apply -f k8s/burst/10-ollama-burst.yaml
  kubectl -n ai rollout status deployment/ollama-burst --timeout=900s

  echo "==> prod chat-api-burst (same tag as prod)"
  tag=$(helm get values chatbot-prod -n chatbot-prod -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["image"]["tag"])')
  PROD_APPROVED=yes ./scripts/06-deploy.sh prod "$tag"
  echo; echo "Burst capacity is up. Check it: make burst-test. Remove it: make burst-down"
}

test_burst() {
  fail=0
  check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got '$2', want '$3')"; fail=1; fi; }
  ready_status=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  check "AWS node joined and Ready" "$ready_status" True
  check "node labelled cloud=aws" "$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.qwenops\.io/cloud}' 2>/dev/null)" aws
  check "node tainted: burst pods only" \
    "$(kubectl get node "$NODE" -o jsonpath='{.spec.taints[?(@.key=="qwenops.io/burst")].effect}' 2>/dev/null)" NoSchedule
  check "ollama-burst ready on the AWS node" \
    "$(kubectl -n ai get pods -l app.kubernetes.io/name=ollama-burst --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)" true
  want=$(kubectl -n chatbot-prod get deploy chat-api-burst -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  got=$(kubectl -n chatbot-prod get pods -l chatbot.io/pool=burst --field-selector spec.nodeName=$NODE \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c true || true)
  check "chat-api-burst pods ready on the AWS node (db + model reachable)" "$got" "$want"

  # Postgres sees the burst pods' connections, over TLS.
  ips=$(kubectl -n chatbot-prod get pods -l chatbot.io/pool=burst -o jsonpath='{.items[*].status.podIP}' | tr ' ' ',')
  q="select count(*) filter (where s.ssl), count(*) from pg_stat_activity a join pg_stat_ssl s using (pid)
     where a.client_addr::text = any(string_to_array('$ips', ','))"
  res=$(kubectl -n data exec postgres-0 -c postgres -- psql -U postgres -Atc "$q" 2>/dev/null || echo "0|0")
  tls=${res%%|*}; all=${res##*|}
  if [ "${all:-0}" -gt 0 ] && [ "$tls" = "$all" ]; then echo "PASS  burst pods use Postgres at home over TLS ($all connections)"
  else echo "FAIL  burst pods' Postgres connections: $tls of $all over TLS"; fail=1; fi

  # A real answer from the model on the AWS node, asked by a burst pod.
  pod=$(kubectl -n chatbot-prod get pods -l chatbot.io/pool=burst -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  answer=$(kubectl -n chatbot-prod exec "$pod" -c chat-api -- python -c '
import json, os, urllib.request
body = json.dumps({"model": os.environ["MODEL"], "prompt": "Reply with one word: hello", "stream": False}).encode()
req = urllib.request.Request(os.environ["OLLAMA_URL"] + "/api/generate", body, {"Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req, timeout=60))["response"].strip()[:40])' 2>/dev/null || true)
  if [ -n "$answer" ]; then echo "PASS  model on the AWS node answers a burst pod (\"$answer\")"
  else echo "FAIL  no answer from ollama-burst"; fail=1; fi

  # Nothing else landed on the AWS node (DaemonSet pods from kube-system are fine).
  others=$(kubectl get pods -A --field-selector spec.nodeName=$NODE -o json | python3 -c '
import json, sys
ok = {("ai", "ollama-burst"), ("chatbot-prod", "burst")}
for p in json.load(sys.stdin)["items"]:
    ns, l = p["metadata"]["namespace"], p["metadata"].get("labels", {})
    if ns == "kube-system" or (ns, l.get("app.kubernetes.io/name")) in ok or (ns, l.get("chatbot.io/pool")) in ok:
        continue
    print(ns + "/" + p["metadata"]["name"])')
  check "only burst pods on the AWS node" "${others:-none}" none
  check "burst pods use the burst quota, not prod's" \
    "$(kubectl -n chatbot-prod get quota burst -o jsonpath='{.status.used.pods}')" "$want"

  # The Capacity page sees the node on its AWS side (Prometheus scrapes it every 60 s).
  running=""
  for _ in $(seq 18); do
    running=$(curl -fsS --cacert certs/chatbot-local-ca.crt --resolve chatbot.local:443:127.0.0.1 \
              https://chatbot.local/api/capacity 2>/dev/null \
              | python3 -c 'import json,sys; print(json.load(sys.stdin)["aws"]["burst"]["running"])' 2>/dev/null || true)
    [ "$running" = True ] && break; sleep 10
  done
  check "Capacity page shows the AWS node" "$running" True
  exit "$fail"
}

down() {
  NEED_ROOT=0
  echo "==> prod without burst pods"
  if kubectl -n chatbot-prod get deploy chat-api-burst >/dev/null 2>&1; then
    tag=$(helm get values chatbot-prod -n chatbot-prod -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["image"]["tag"])')
    BURST=off PROD_APPROVED=yes ./scripts/06-deploy.sh prod "$tag" >/dev/null
    echo "    chat-api-burst removed"
  fi
  kubectl delete -f k8s/burst/10-ollama-burst.yaml --ignore-not-found >/dev/null
  kubectl -n chatbot-prod delete configmap postgres-ca --ignore-not-found >/dev/null

  echo "==> removing the node from the cluster"
  kubectl delete node "$NODE" --ignore-not-found >/dev/null
  kubectl -n kube-system delete secret "$NODE.node-password.k3s" --ignore-not-found >/dev/null
  kubectl -n kube-system delete secret -l qwenops.io/burst=true --ignore-not-found >/dev/null   # join tokens

  echo "==> home wg0 down"
  if wg_up; then root wg-quick down wg0; fi
  root rm -f "$WG_CONF"

  echo "==> destroying the AWS node"
  $TF init -input=false >/dev/null
  TF_VAR_home_cidr=0.0.0.0/32 TF_VAR_home_lan_ip=x TF_VAR_home_public_key=x TF_VAR_aws_private_key=x \
  TF_VAR_k3s_token=x TF_VAR_k3s_version=x TF_VAR_apparmor_profile=x \
    $TF destroy -input=false -auto-approve
  rm -f "$DIR/burst.key" "$DIR/burst.pub" "$DIR/wg0.conf"
  left=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Stack,Values=burst \
         --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo "?")
  echo "AWS resources still tagged Stack=burst: $left (terminated instances and tag listings can lag)"
  [ "$NEED_ROOT" = 0 ] || echo "Run the sudo lines above to finish the home side."
}

status() {
  id=$(tf_out instance_id)
  if [ -n "$id" ]; then
    state=$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "?")
    echo "AWS node: $id $(tf_out public_ip) $(tf_out market), $state"
  else echo "AWS node: none"; fi
  if wg_up; then echo "home wg0: up"; else echo "home wg0: down"; fi
  kubectl get node "$NODE" -o wide 2>/dev/null || echo "k8s node $NODE: not in the cluster"
  kubectl get pods -A --field-selector spec.nodeName=$NODE -o wide 2>/dev/null | sed 1d || true
}

case "${1:-}" in
  prepare) prepare ;; up) up ;; ready) ready ;; test) test_burst ;; down) down ;; status) status ;;
  *) echo "usage: $0 prepare|up|ready|test|down|status"; exit 2 ;;
esac
