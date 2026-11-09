#!/usr/bin/env bash
# Phase 7: the Raspberry Pi gateway. The Pi answers for chatbot.local & co., passes everything through
# to the server, and when the server is asleep shows "Waking up..." and sends the magic packet.
#
#   ./scripts/18-pi-gateway.sh install     # certificate + copy + set up the Pi (asks the Pi's sudo password)
#   ./scripts/18-pi-gateway.sh test        # checks from the server (no sudo)
#   ./scripts/18-pi-gateway.sh simulate    # pretend the server sleeps: waking page + magic packet (sudo on Pi)
#   ./scripts/18-pi-gateway.sh status
#   ./scripts/18-pi-gateway.sh quiet MIN    # planned work (reboot, BIOS): no "server down" alert for MIN minutes
#   ./scripts/18-pi-gateway.sh remove
# Which Pi: PI=user@address (default rasppi@192.168.1.104). Give the Pi and the server fixed addresses.
# The Pi also watches the server and sends urgent ntfy alerts when it's down without an announced sleep;
# the server announces sleeps with a token kept in secret pi-gateway (namespace monitoring).
set -euo pipefail
cd "$(dirname "$0")/.."
PI="${PI:-rasppi@192.168.1.104}"
PI_IP="${PI#*@}"
NAMES="chatbot.local dev.chatbot.local qa.chatbot.local jenkins.chatbot.local"
IFACE=$(ip -4 route show default | awk '{print $5; exit}')
SERVER_IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
SERVER_MAC=$(cat "/sys/class/net/$IFACE/address")
# The word after "brd" (not a fixed column: "metric 100" can come first).
BROADCAST=$(ip -o -4 addr show dev "$IFACE" | awk '{for (i = 1; i < NF; i++) if ($i == "brd") { print $(i+1); exit }}')
REMOTE=qwenops-gateway-install

install() {
  echo "==> certificate for the Pi's waking page"
  kubectl apply -f k8s/edge/10-pi-gateway-tls.yaml >/dev/null
  kubectl -n cert-manager wait certificate/pi-gateway-tls --for=condition=Ready --timeout=120s >/dev/null
  pi_if=$(ssh -o BatchMode=yes "$PI" "ip -4 route show default | awk '{print \$5; exit}'")
  tmp=$(mktemp -d); chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
  cp -r pi/setup.sh pi/gateway "$tmp/"
  kubectl -n cert-manager get secret pi-gateway-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp/tls.crt"
  (umask 077; kubectl -n cert-manager get secret pi-gateway-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$tmp/tls.key")
  cp certs/chatbot-local-ca.crt "$tmp/ca.crt"
  # Token for the server's "going to sleep" notices (made once, kept in the cluster), and the ntfy topic.
  if ! kubectl -n monitoring get secret pi-gateway >/dev/null 2>&1; then
    kubectl -n monitoring create secret generic pi-gateway --from-literal=SLEEP_TOKEN="$(openssl rand -hex 24)" \
      --from-literal=PI_URL="http://$PI_IP:8082" >/dev/null
  fi
  kubectl -n monitoring patch secret pi-gateway -p "{\"stringData\":{\"PI_URL\":\"http://$PI_IP:8082\"}}" >/dev/null
  token=$(kubectl -n monitoring get secret pi-gateway -o jsonpath='{.data.SLEEP_TOKEN}' | base64 -d)
  topic=$(kubectl -n monitoring get secret ntfy -o jsonpath='{.data.NTFY_TOPIC}' 2>/dev/null | base64 -d || true)
  [[ -n $topic ]] || echo "    note: no ntfy topic yet (make alerts-topic): the Pi will log 'server down' but can't alert"
  (umask 077; cat > "$tmp/gateway.env" <<ENV
SERVER_IP=$SERVER_IP
SERVER_MAC=$SERVER_MAC
BROADCAST=${BROADCAST:-255.255.255.255}
NAMES="$NAMES"
IFACE=$pi_if
CHECK_HOST=chatbot.local
SLEEP_TOKEN=$token
NTFY_TOPIC=$topic
ENV
  )
  echo "    server $SERVER_IP ($SERVER_MAC), broadcast $BROADCAST; Pi $PI_IP on $pi_if"
  echo "==> copying to $PI and setting it up (the Pi asks for its sudo password)"
  ssh -o BatchMode=yes "$PI" "rm -rf ~/$REMOTE && mkdir -m 700 ~/$REMOTE"
  scp -q -r "$tmp"/* "$PI:$REMOTE/"
  # The private key only exists in the temporary folder until setup has installed it.
  ssh -t "$PI" "sudo bash ~/$REMOTE/setup.sh install; rc=\$?; rm -rf ~/$REMOTE; exit \$rc"
  echo; test_gw || true
}

test_gw() {
  c="curl -sS -m 8 --cacert certs/chatbot-local-ca.crt"
  fail=0
  ok() { echo "PASS  $1"; }; bad() { echo "FAIL  $1"; fail=1; }
  # Through the Pi, with the server awake: the answer must come from the server (its certificate).
  for h in chatbot.local dev.chatbot.local; do
    code=$($c -o /dev/null -w '%{http_code}' --resolve "$h:443:$PI_IP" "https://$h/api/healthz" 2>&1 || true)
    [[ $code == 200 ]] && ok "https://$h through the Pi reaches the server" || bad "$h through the Pi: $code"
  done
  srv=$(echo | openssl s_client -connect "$PI_IP:443" -servername chatbot.local 2>/dev/null | openssl x509 -noout -serial 2>/dev/null)
  pi=$(kubectl -n cert-manager get secret pi-gateway-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial)
  [[ -n $srv && $srv != "$pi" ]] && ok "TLS passes through untouched (server's own certificate)" || bad "certificate through the Pi: $srv"
  [[ $($c -o /dev/null -w '%{http_code}' --resolve "chatbot.local:80:$PI_IP" http://chatbot.local/) == 301 ]] \
    && ok "plain http through the Pi redirects to https" || bad "http through the Pi"
  # On the Pi: names announced, services up, the waker sees the server as ready.
  out=$(ssh -o BatchMode=yes "$PI" "for n in $NAMES; do avahi-resolve -4 -n \$n 2>/dev/null; done; \
        for s in nginx qwenops-waker qwenops-mdns; do echo svc \$s \$(systemctl is-active \$s); done; \
        curl -sS -m 5 http://127.0.0.1:8081/api/status")
  for n in $NAMES; do
    echo "$out" | grep -q "^$n	$PI_IP$" && ok "$n announced -> $PI_IP" || bad "$n not announced as $PI_IP"
  done
  for s in nginx qwenops-waker qwenops-mdns; do
    echo "$out" | grep -q "^svc $s active" && ok "$s running on the Pi" || bad "$s not running"
  done
  echo "$out" | grep -q '"ready"' && ok "waker sees the server as ready" || bad "waker status: $(echo "$out" | tail -1)"
  # The watcher: reachable from the server, sees it up, refuses notices without the right token.
  w=$(curl -sS -m 5 "http://$PI_IP:8082/watch" 2>&1 || true)
  [[ $w == *'"server": "up"'* ]] && ok "watcher sees the server up" || bad "watcher: $w"
  [[ $w == *'"alerts_to_phone": true'* ]] && ok "watcher can alert your phone (ntfy topic set)" || bad "watcher has no ntfy topic: make alerts-topic, then make pi-gateway"
  [[ $(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H 'X-Token: wrong' -d '{"until": 1}' "http://$PI_IP:8082/sleeping") == 401 ]] \
    && ok "sleep notices need the token" || bad "sleep notice without token not refused"
  return $fail
}

case "${1:-}" in
  install) install ;;
  test) test_gw ;;
  simulate) ssh -t "$PI" "sudo /opt/qwenops-gateway-setup/setup.sh simulate" ;;
  quiet)
    min=${2:?usage: $0 quiet MINUTES}; [[ $min =~ ^[0-9]+$ ]] || { echo "minutes must be a number"; exit 1; }
    token=$(kubectl -n monitoring get secret pi-gateway -o jsonpath='{.data.SLEEP_TOKEN}' | base64 -d)
    curl -fsS -m 5 -H "X-Token: $token" -d "{\"until\": $(( $(date +%s) + min * 60 )), \"reason\": \"maintenance\"}" \
      "http://$PI_IP:8082/sleeping" >/dev/null && echo "The Pi won't send 'server down' alerts for $min minutes." ;;
  status) curl -sS -m 5 "http://$PI_IP:8082/watch"; echo; ssh -o BatchMode=yes "$PI" "for s in nginx qwenops-waker qwenops-mdns avahi-daemon; do printf '%-16s %s\n' \$s \$(systemctl is-active \$s); done; curl -sS -m 5 http://127.0.0.1:8081/api/status; echo" ;;
  remove) ssh -t "$PI" "sudo /opt/qwenops-gateway-setup/setup.sh remove" ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
