#!/usr/bin/env bash
# Public site backend (Phase 9b). Runs ON the Raspberry Pi as root (scripts/21-public-chat.sh copies it over).
#   public-setup.sh install   Tailscale + nginx's JavaScript module, the public gateway on 127.0.0.1:8090,
#                             then a public HTTPS address with Tailscale Funnel (asks you to log in once)
#   public-setup.sh off       stop Funnel (the public site's chat goes quiet; nothing else changes)
#   public-setup.sh remove    stop Funnel and remove the public gateway (Tailscale stays installed)
#
# The path:  visitor → Netlify (signs the request) → Tailscale Funnel (TLS) → this Pi, nginx 127.0.0.1:8090
#            → checks Netlify's signature, allows only the public paths (chat, Pulse, Capacity, Backups
#              view, Pipeline + logs, Be a Dev, theme.json; never "Back up now"), limits each visitor
#            → https://<server>:443 as chatbot.local (prod), adding the edge secret and the visitor's address.
# If the server is asleep, /api/status and /api/wake go to the waker, which sends the magic packet.
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
ETC=/etc/qwenops-gateway
PUB=$ETC/public
CONF=/etc/nginx/conf.d/qwenops-public.conf

gateway_conf() {   # $1 server address, $2 edge secret
  cat <<CONF
# QwenOps public chat gateway (pi/public-setup.sh). Only Tailscale Funnel reaches it (127.0.0.1).
js_import qwenops_public from $PUB/verify.js;
js_set \$qwenops_signed qwenops_public.verify;

# The visitor's address as Netlify saw it (trusted only after the signature check below): Netlify's
# client-address header, else the first address in X-Forwarded-For, else the connection's.
map \$http_x_forwarded_for \$qwenops_xff {
  "~^(?<first>[^,\\s]+)" \$first;
  default \$remote_addr;
}
map \$http_x_nf_client_connection_ip \$qwenops_visitor {
  ""      \$qwenops_xff;
  default \$http_x_nf_client_connection_ip;
}
# Chat: 10 a minute per visitor in chat-api (as at home); the Pi only stops floods. Pages poll every 3-10 s.
limit_req_zone \$qwenops_visitor zone=qwenops_chat:1m rate=12r/m;
limit_req_zone \$qwenops_visitor zone=qwenops_api:1m rate=180r/m;
limit_conn_zone \$server_name zone=qwenops_all:1m;

server {
  listen 127.0.0.1:8090;
  server_name qwenops-public;
  server_tokens off;
  client_max_body_size 16k;
  access_log /var/log/nginx/qwenops-public.log;
  limit_req_status 429;
  limit_conn_status 503;

  if (\$qwenops_signed != "1") { return 403 '{"detail": "only through the public site"}\n'; }

  # To prod, as chatbot.local, checked against the home CA.
  proxy_ssl_server_name on;
  proxy_ssl_name chatbot.local;
  proxy_ssl_verify on;
  proxy_ssl_trusted_certificate $ETC/ca.crt;
  proxy_connect_timeout 2s;
  proxy_set_header Host chatbot.local;
  proxy_set_header X-Nf-Sign "";
  proxy_set_header X-QwenOps-Edge "$2";
  proxy_set_header X-QwenOps-Client \$qwenops_visitor;
  default_type application/json;

  location = /api/chat {
    limit_req zone=qwenops_chat burst=5 nodelay;
    limit_conn qwenops_all 6;                 # at most 6 public chats streaming at once
    proxy_pass https://$1;
    proxy_buffering off;                      # stream the reply word by word
    proxy_read_timeout 120s;
    error_page 502 504 = @asleep_json;
  }
  # Read-only pages and Be a Dev. /api/backups/run ("Back up now") is not in the list: home only.
  location ~ ^/api/(history|pulse|capacity|backups|backups/log|pipeline|pipeline/log|themes|theme)\$ {
    limit_req zone=qwenops_api burst=60 nodelay;
    proxy_pass https://$1;
    error_page 502 504 = @asleep_json;
  }
  location = /theme.json {                    # the public site shows prod's live colour
    limit_req zone=qwenops_api burst=60 nodelay;
    proxy_pass https://$1;
    error_page 502 504 = @asleep_json;
  }
  location ~ ^/api/(status|wake)\$ {
    limit_req zone=qwenops_api burst=60 nodelay;
    proxy_pass https://$1;
    error_page 502 504 = @waker;              # server asleep: the waker answers and wakes it
  }
  location @waker { proxy_pass http://127.0.0.1:8081; }
  location @asleep_json { return 503 '{"detail": "The home server is waking up. Try again in a minute."}\n'; }
  location / { return 404 '{"detail": "not available on the public site"}\n'; }
}
CONF
}

install_all() {
  . ./public.env      # SERVER_IP, EDGE_SECRET
  echo "==> packages: Tailscale (official apt repository) and nginx's JavaScript module"
  codename=$(. /etc/os-release; echo "$VERSION_CODENAME")
  if ! command -v tailscale >/dev/null; then
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
    apt-get update -q >/dev/null
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q tailscale libnginx-mod-http-js >/dev/null

  echo "==> public gateway (nginx 127.0.0.1:8090)"
  install -d -m 0750 -g www-data "$PUB"
  install -m 0644 public/verify.js "$PUB/verify.js"
  install -m 0640 -g www-data netlify.secret "$PUB/netlify.secret"   # nginx workers read it per request
  (umask 077; gateway_conf "$SERVER_IP" "$EDGE_SECRET" > "$CONF")     # holds the edge secret: root only
  nginx -t 2>&1 | grep -v "syntax is ok" || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx
  sig=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/api/status)
  [[ $sig == 403 ]] && echo "    unsigned request refused (403): good" || { echo "    expected 403 without a signature, got $sig"; exit 1; }

  echo "==> Tailscale"
  systemctl enable --now tailscaled >/dev/null 2>&1
  if ! tailscale status >/dev/null 2>&1; then
    echo "    Log in: open the link below in a browser and approve this Pi (a free Tailscale account is enough)."
    tailscale up --hostname=qwenops
  fi
  echo "==> Funnel: public HTTPS → 127.0.0.1:8090"
  echo "    The first time, Tailscale may print a link to turn on HTTPS and Funnel for your tailnet: open it, approve."
  tailscale funnel --bg 8090
  tailscale funnel status
  name=$(tailscale status --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
  echo "PUBLIC_URL=https://$name"
}

case "${1:-}" in
  install) install_all ;;
  off) tailscale serve reset || true; echo "Funnel off: the public site's chat is closed." ;;
  remove) tailscale serve reset || true; rm -rf "$PUB" "$CONF"; nginx -t >/dev/null 2>&1 && systemctl reload nginx; echo "Public gateway removed." ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
