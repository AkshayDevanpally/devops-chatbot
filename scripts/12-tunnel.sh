#!/usr/bin/env bash
# Phase 5 tunnel test: home Postgres reached from AWS over WireGuard, dialled out from home.
#
#   ./scripts/12-tunnel.sh up      # AWS endpoint (Terraform) + home wg0 config
#   ./scripts/12-tunnel.sh test    # checks run on the AWS side through SSM
#   ./scripts/12-tunnel.sh down    # home wg0 down + terraform destroy (nothing in AWS holds data)
#   ./scripts/12-tunnel.sh status
#
# Needs `make db-tls` first. Keys live outside the repo in ~/.config/qwenops-tunnel (0700):
# the home key is kept, the AWS key is made fresh on every `up` and deleted on `down`.
# Steps that need root (installing wg0.conf, wg-quick) run with sudo, or are printed when sudo
# would ask for a password.
set -euo pipefail
cd "$(dirname "$0")/.."

export AWS_PROFILE="${AWS_PROFILE:-chatbot}"
TF="terraform -chdir=terraform/tunnel"
DIR="${XDG_CONFIG_HOME:-$HOME/.config}/qwenops-tunnel"
WG_CONF=/etc/wireguard/wg0.conf

root() {  # run as root if sudo works without a prompt, otherwise tell the user what to run
  if sudo -n true 2>/dev/null; then sudo "$@"; else
    echo "    needs root, run:  sudo $*"; NEED_ROOT=1
  fi
}

tf_out() { $TF output -raw "$1" 2>/dev/null || true; }

up() {
  kubectl -n data get secret postgres-tls >/dev/null 2>&1 || { echo "run 'make db-tls' first"; exit 1; }
  mkdir -p "$DIR"; chmod 700 "$DIR"; umask 077

  echo "==> keys"
  [ -s "$DIR/home.key" ] || wg genkey > "$DIR/home.key"
  wg pubkey < "$DIR/home.key" > "$DIR/home.pub"
  wg genkey > "$DIR/aws.key"
  wg pubkey < "$DIR/aws.key" > "$DIR/aws.pub"

  home_ip=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
  echo "    home public IP: $home_ip (only it may reach the AWS endpoint)"

  echo "==> AWS endpoint (Terraform)"
  $TF init -input=false >/dev/null
  TF_VAR_home_cidr="$home_ip/32" \
  TF_VAR_home_public_key="$(cat "$DIR/home.pub")" \
  TF_VAR_aws_private_key="$(cat "$DIR/aws.key")" \
  TF_VAR_postgres_ca="$(kubectl -n data get secret postgres-tls -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
    $TF apply -input=false -auto-approve
  ip=$(tf_out public_ip)

  echo "==> home wg0 config -> $DIR/wg0.conf"
  cat > "$DIR/wg0.conf" <<CONF
# QwenOps tunnel, home end. Written by scripts/12-tunnel.sh; replaced on every 'up'.
[Interface]
Address = 10.200.0.1/24
PrivateKey = $(cat "$DIR/home.key")

[Peer]
# AWS endpoint $(tf_out instance_id)
PublicKey = $(cat "$DIR/aws.pub")
Endpoint = $ip:51820
AllowedIPs = 10.200.0.2/32
PersistentKeepalive = 25
CONF

  NEED_ROOT=0
  root wg-quick down wg0 2>/dev/null || true
  root install -m 600 -o root -g root "$DIR/wg0.conf" "$WG_CONF"
  root wg-quick up wg0
  if [ "$NEED_ROOT" = 1 ]; then
    echo; echo "Run the sudo lines above (in order), then: make tunnel-test"
  else
    echo; echo "Tunnel up. Next: make tunnel-test"
  fi
}

ssm_run() {  # run a shell script on the AWS node, print its output
  local id cmd status
  id=$(tf_out instance_id)
  cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
        --parameters "$(jq -n --arg s "$1" '{commands: [$s]}')" --query Command.CommandId --output text)
  for _ in $(seq 60); do
    status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
             --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Pending|InProgress|Delayed) sleep 2 ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text
}

test_tunnel() {
  id=$(tf_out instance_id)
  [ -n "$id" ] || { echo "no AWS endpoint: run 'up' first"; exit 1; }

  echo "==> waiting for the AWS node to register with SSM and finish setup"
  for i in $(seq 60); do
    online=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
             --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
    [ "$online" = Online ] && break
    [ "$i" -lt 60 ] || { echo "node never came online in SSM"; exit 1; }; sleep 5
  done
  for i in $(seq 30); do
    [ "$(ssm_run 'test -f /var/run/tunnel-ready && echo yes' | tr -d '[:space:]')" = yes ] && break
    [ "$i" -lt 30 ] || { echo "node setup (user data) did not finish"; exit 1; }; sleep 5
  done

  echo "==> checks (run on the AWS node)"
  # The AWS node has no `wg` tool (systemd-networkd runs WireGuard), so ping proves the tunnel. No real password is sent: reaching
  # "password authentication failed" proves TLS verify-full passed and pg_hba.conf allowed the login.
  out=$(ssm_run '
pg() { psql "host=10.200.0.1 connect_timeout=8 sslrootcert=/etc/postgres-ca.crt password=not-the-password $1" -c "select 1" 2>&1 | head -1; }
echo "PING $(ping -c 3 -W 2 10.200.0.1 >/dev/null 2>&1 && echo ok || echo fail)"
echo "APP $(pg "dbname=chat_dev user=chat_dev sslmode=verify-full")"
echo "SUPER $(pg "dbname=postgres user=postgres sslmode=verify-full")"
echo "OTHERDB $(pg "dbname=chat_prod user=chat_dev sslmode=verify-full")"
echo "NOTLS $(pg "dbname=chat_dev user=chat_dev sslmode=disable")"
echo "WRONGNAME $(psql "host=db.example.com hostaddr=10.200.0.1 connect_timeout=8 sslrootcert=/etc/postgres-ca.crt sslmode=verify-full dbname=chat_dev user=chat_dev" -c "select 1" 2>&1 | head -1)"
')
  fail=0
  line() { echo "$out" | grep "^$1 " | head -1 | cut -d' ' -f2-; }
  check() {  # name, key, expected substring
    local got; got=$(line "$2")
    if echo "$got" | grep -qi -- "$3"; then echo "PASS  $1"; else echo "FAIL  $1"; echo "      got: $got"; fail=1; fi
  }
  check "home end of the tunnel answers ping"                         PING     "ok"
  check "app login reaches Postgres: TLS verify-full + SCRAM asked"   APP      "password authentication failed for user \"chat_dev\""
  check "superuser refused over the tunnel"                           SUPER    "pg_hba.conf rejects connection"
  check "app login refused for another env's database"                OTHERDB  "pg_hba.conf rejects connection"
  check "connection without TLS refused"                              NOTLS    "pg_hba.conf rejects connection"
  check "certificate refused for a wrong host name"                   WRONGNAME "does not match host name"
  # Home side: Postgres must see the AWS tunnel address, not a NAT address, or the rules can't apply.
  if kubectl -n data logs postgres-0 -c postgres --since=5m | grep -q 'host "10.200.0.2"'; then
    echo "PASS  Postgres sees the caller as 10.200.0.2 (tunnel address kept)"
  else echo "FAIL  Postgres never logged the tunnel address 10.200.0.2"; fail=1; fi
  exit "$fail"
}

down() {
  NEED_ROOT=0
  echo "==> home wg0 down"
  if ip link show wg0 >/dev/null 2>&1; then root wg-quick down wg0; fi
  root rm -f "$WG_CONF"
  echo "==> destroying the AWS endpoint"
  $TF init -input=false >/dev/null
  TF_VAR_home_cidr=0.0.0.0/32 TF_VAR_home_public_key=x TF_VAR_aws_private_key=x TF_VAR_postgres_ca=x \
    $TF destroy -input=false -auto-approve
  rm -f "$DIR/aws.key" "$DIR/aws.pub" "$DIR/wg0.conf"
  left=$(aws resourcegroupstaggingapi get-resources --tag-filters Key=Stack,Values=tunnel \
         --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo "?")
  echo "AWS resources still tagged Stack=tunnel: $left (tag listings can lag a few minutes)"
  [ "$NEED_ROOT" = 0 ] || echo "Run the sudo lines above to finish the home side."
}

status() {
  echo "AWS endpoint: $(tf_out instance_id) $(tf_out public_ip)"
  if ip link show wg0 >/dev/null 2>&1; then
    echo "home wg0: up"; root wg show wg0 2>/dev/null | grep -E "endpoint|handshake|transfer" || true
  else echo "home wg0: down"; fi
}

case "${1:-}" in
  up) up ;; test) test_tunnel ;; down) down ;; status) status ;;
  *) echo "usage: $0 up|test|down|status"; exit 2 ;;
esac
