#!/usr/bin/env bash
# Runs ON the Raspberry Pi, as root (scripts/18-pi-gateway.sh copies everything over and runs it).
#   setup.sh install    nginx pass-through + fallback, waker, mDNS names
#   setup.sh simulate   pretend the server is asleep, check the waking page and magic packet, restore
#   setup.sh remove
# Settings come from ./gateway.env (SERVER_IP, SERVER_MAC, BROADCAST, NAMES, IFACE).
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
. ./gateway.env
ETC=/etc/qwenops-gateway
APP=/opt/qwenops-gateway

stream_conf() {   # $1 = server address
  cat <<CONF
# QwenOps gateway (pi/setup.sh). Every connection goes straight through to the server (TLS untouched).
# If the server doesn't answer within 1 s (asleep), the local "waking up" site takes over.
upstream qwenops_https { server $1:443 max_fails=1 fail_timeout=3s; server 127.0.0.1:8443 backup; }
upstream qwenops_http  { server $1:80  max_fails=1 fail_timeout=3s; server 127.0.0.1:8080 backup; }
server { listen 443; listen [::]:443; proxy_pass qwenops_https; proxy_connect_timeout 1s; proxy_timeout 1h; }
server { listen 80;  listen [::]:80;  proxy_pass qwenops_http;  proxy_connect_timeout 1s; proxy_timeout 10m; }
CONF
}

install_all() {
  echo "==> packages"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q nginx libnginx-mod-stream avahi-daemon avahi-utils >/dev/null

  echo "==> certificate for the waking page (from the home CA)"
  install -d -m 0755 "$ETC"
  install -m 0644 tls.crt "$ETC/tls.crt"; install -m 0644 ca.crt "$ETC/ca.crt"
  install -m 0640 -g www-data tls.key "$ETC/tls.key"
  install -m 0644 gateway.env "$ETC/gateway.env"

  echo "==> waker (magic packet + waking page)"
  install -d -m 0755 "$APP"
  install -m 0644 gateway/waker.py gateway/waking.html "$APP/"
  cat > /etc/systemd/system/qwenops-waker.service <<UNIT
[Unit]
Description=QwenOps waker: waking page and Wake-on-LAN for the home server
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=$ETC/gateway.env
ExecStart=/usr/bin/python3 -I -u $APP/waker.py
DynamicUser=yes
Restart=always
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT

  echo "==> nginx"
  install -d /etc/nginx/stream.d
  stream_conf "$SERVER_IP" > /etc/nginx/stream.d/qwenops.conf
  grep -q 'stream.d/\*.conf' /etc/nginx/nginx.conf || printf '\nstream { include /etc/nginx/stream.d/*.conf; }\n' >> /etc/nginx/nginx.conf
  rm -f /etc/nginx/sites-enabled/default        # ports 80/443 belong to the stream pass-through
  cat > /etc/nginx/conf.d/qwenops-waking.conf <<CONF
# Only reached when the server is asleep (fallback of the stream pass-through).
server {
  listen 127.0.0.1:8443 ssl;
  server_name _;
  ssl_certificate     $ETC/tls.crt;
  ssl_certificate_key $ETC/tls.key;
  ssl_protocols TLSv1.2 TLSv1.3;
  server_tokens off;
  # Close the connection after every answer. A browser reuses an open connection, and this one is tied
  # to the waking page: without this, the reload after "ready" would land here again (a reload loop).
  # A fresh connection goes through the pass-through again, which reaches the server once it's up.
  keepalive_timeout 0;
  location / { proxy_pass http://127.0.0.1:8081; proxy_set_header Host \$host; }
}
server { listen 127.0.0.1:8080; server_tokens off; keepalive_timeout 0; location / { return 301 https://\$host\$request_uri; } }
CONF

  echo "==> mDNS names on $IFACE: $NAMES"
  id qwenops >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --groups netdev qwenops
  sed -i -E "s/^#?allow-interfaces=.*/allow-interfaces=$IFACE/" /etc/avahi/avahi-daemon.conf
  cat > /usr/local/sbin/qwenops-mdns <<'SH'
#!/bin/sh
# Announce the QwenOps names with this Pi's current address. Exits (and systemd restarts it) if the
# address changes or any announcement stops, so it never claims to announce while nothing runs.
NAMES="$1"; IFACE="$2"
addr() { ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1; }
ip=$(addr); [ -n "$ip" ] || { echo "no IPv4 address on $IFACE yet"; exit 1; }
pids=""
for n in $NAMES; do avahi-publish -a -R "$n" "$ip" & pids="$pids $!"; done   # errors go to the journal
trap 'kill $pids 2>/dev/null' EXIT TERM
echo "announcing $NAMES -> $ip"
while sleep 30; do
  [ "$(addr)" = "$ip" ] || { echo "address changed: restarting"; exit 1; }
  for p in $pids; do kill -0 "$p" 2>/dev/null || { echo "an announcement stopped: restarting"; exit 1; }; done
done
SH
  chmod 755 /usr/local/sbin/qwenops-mdns
  cat > /etc/systemd/system/qwenops-mdns.service <<UNIT
[Unit]
Description=Announce QwenOps names (chatbot.local, ...) on the home network over mDNS
Requires=avahi-daemon.service
After=avahi-daemon.service network-online.target

[Service]
ExecStart=/usr/local/sbin/qwenops-mdns "$NAMES" $IFACE
# A fixed system user in netdev: the D-Bus policy for avahi trusts that group, and a DynamicUser
# account wasn't able to publish (the announcements died silently on the first install).
User=qwenops
Group=qwenops
SupplementaryGroups=netdev
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
UNIT

  # Keep this script and the settings (not the key) for later "simulate" and "remove".
  install -d -m 0755 /opt/qwenops-gateway-setup
  install -m 0755 setup.sh /opt/qwenops-gateway-setup/setup.sh
  install -m 0644 gateway.env /opt/qwenops-gateway-setup/gateway.env

  systemctl daemon-reload
  nginx -t
  systemctl restart avahi-daemon
  systemctl enable --now qwenops-waker qwenops-mdns >/dev/null 2>&1
  systemctl restart qwenops-waker qwenops-mdns
  systemctl enable nginx >/dev/null 2>&1; systemctl reload-or-restart nginx
  sleep 2
  for s in nginx qwenops-waker qwenops-mdns avahi-daemon; do printf '%-16s %s\n' "$s" "$(systemctl is-active $s)"; done
}

simulate() {
  # Point the pass-through at an unused address (TEST-NET), check the fallback, then restore.
  echo "==> pretending the server is asleep"
  stream_conf 192.0.2.1 > /etc/nginx/stream.d/qwenops.conf && systemctl reload nginx
  trap 'stream_conf "$SERVER_IP" > /etc/nginx/stream.d/qwenops.conf; systemctl reload nginx; echo "==> restored: pass-through to $SERVER_IP"' EXIT
  sleep 1
  c="curl -sS -m 8 --cacert $ETC/ca.crt --resolve chatbot.local:443:127.0.0.1 --resolve chatbot.local:80:127.0.0.1"
  fail=0
  ok() { echo "PASS  $1"; }; bad() { echo "FAIL  $1"; fail=1; }
  t0=$(date +%s.%N); page=$($c https://chatbot.local/ 2>&1); t1=$(date +%s.%N)
  [[ $($c -sI https://chatbot.local/ | tr -d '\r' | grep -i '^connection:') == *close* ]] \
    && ok "waking page closes its connection (no reload loop)" || bad "waking page keeps the connection open"
  echo "$page" | grep -q "Waking it up" && ok "waking page shown, trusted certificate ($(printf '%.1f' "$(echo "$t1 - $t0" | bc)") s)" || bad "waking page: $(echo "$page" | head -c 120)"
  [[ $($c -o /dev/null -w '%{http_code} %{redirect_url}' http://chatbot.local/pulse/) == "301 https://chatbot.local/pulse/" ]] \
    && ok "plain http redirects to https" || bad "http redirect"
  [[ $($c -X POST https://chatbot.local/api/wake) == *accepted* ]] && ok "POST /api/wake accepted" || bad "/api/wake"
  st=$($c https://chatbot.local/api/status); [[ $st == *'"waking"'* || $st == *'"ready"'* ]] && ok "/api/status answers ($st)" || bad "/api/status: $st"
  [[ $($c -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' https://chatbot.local/api/chat) == 503 ]] \
    && ok "API calls get 503 'waking up'" || bad "api 503"
  journalctl -u qwenops-waker --since "-1 min" --no-pager -o cat | grep -q magic_packet_sent \
    && ok "magic packet sent (to $SERVER_MAC)" || bad "no magic packet logged"
  return $fail
}

remove() {
  systemctl disable --now qwenops-waker qwenops-mdns >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/qwenops-{waker,mdns}.service /usr/local/sbin/qwenops-mdns \
        /etc/nginx/stream.d/qwenops.conf /etc/nginx/conf.d/qwenops-waking.conf
  systemctl daemon-reload; nginx -t && systemctl reload nginx || true
  echo "Removed (nginx and avahi stay installed; $ETC kept)."
}

case "${1:-}" in
  install) install_all ;; simulate) simulate ;; remove) remove ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
