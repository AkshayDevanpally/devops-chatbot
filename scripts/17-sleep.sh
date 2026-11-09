#!/usr/bin/env bash
# Phase 7: the server sleeps when idle and wakes by Wake-on-LAN (a phone app on the home Wi-Fi) or by
# its own clock for the nightly backups.
#
#   sudo ./scripts/17-sleep.sh setup     # once: Wake-on-LAN on, idle check every 5 min, wake timer
#   ./scripts/17-sleep.sh status         # would it sleep now? and why not
#   ./scripts/17-sleep.sh stay-awake     # never sleep until allow-sleep (no sudo)
#   ./scripts/17-sleep.sh allow-sleep
#   sudo ./scripts/17-sleep.sh now [MIN] # sleep right away; with MIN, wake by itself after MIN minutes
#   sudo ./scripts/17-sleep.sh wol-test  # find where Wake-on-LAN breaks (card, delivery, real wake)
#   sudo ./scripts/17-sleep.sh remove    # undo setup
#
# The server sleeps after IDLE_MINUTES with none of: app traffic (chats, Pulse, any /api call), a
# Jenkins build, a backup job, an AWS burst node, an SSH session, the stay-awake switch, or the
# backup window (07:45-10:00 IST = 02:15-04:30 UTC; it wakes itself at 07:50 IST for the backup at 08:00,
# the Sunday restore test at 09:00 and the off-site copy at 09:45). Times are in SLEEP_TZ (IST).
set -euo pipefail
cd "$(dirname "$0")/.."
CONF=/etc/qwenops-sleep.conf
STATE=/var/lib/qwenops-sleep
CHECK=/usr/local/sbin/qwenops-idle-check
IFACE=$(ip -4 route show default | awk '{print $5; exit}')
need_root() { [[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }; }

write_check() {
  cat > "$CHECK" <<'SH'
#!/usr/bin/env bash
# QwenOps idle check (installed by scripts/17-sleep.sh). Runs every 5 minutes as root.
#   qwenops-idle-check          decide, and suspend if idle long enough
#   qwenops-idle-check --dry    only print the decision
set -uo pipefail
. /etc/qwenops-sleep.conf
STATE=/var/lib/qwenops-sleep
DRY=${1:-}
[[ $EUID -eq 0 ]] && export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}   # root: k3s's own; users: theirs
k() { timeout 20 kubectl "$@"; }
now=$(date +%s)
busy=()

# 1. switches and time windows
[[ -e $STATE/stay-awake ]] && busy+=("stay-awake switch is on (make allow-sleep)")
export TZ=${SLEEP_TZ:-UTC}
hm=$(date +%H%M); from=${KEEP_AWAKE_FROM/:/}; to=${KEEP_AWAKE_TO/:/}   # 10#: "0830" is not octal
(( 10#$hm >= 10#$from && 10#$hm < 10#$to )) \
  && busy+=("backup window $KEEP_AWAKE_FROM-$KEEP_AWAKE_TO $(date +%Z)")
# 2. someone connected over SSH (also VS Code Remote)
ssh=$(ss -tnH state established '( sport = :22 )' | wc -l); [[ $ssh -gt 0 ]] && busy+=("$ssh SSH connection(s)")
# 3. a Jenkins build: the agent's java process alone means idle
jp=$(pgrep -c -u jenkins-agent 2>/dev/null || echo 0); [[ $jp -gt 1 ]] && busy+=("Jenkins build running")
# 4. Kubernetes: backup jobs, AWS burst node (cluster unreachable = stay awake, to be safe)
if ! jobs=$(k -n data get jobs -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name} {end}' 2>/dev/null); then
  busy+=("Kubernetes not answering")
else
  [[ -n $jobs ]] && busy+=("backup job running: $jobs")
  burst=$(k get nodes -l qwenops.io/burst=true -o name 2>/dev/null)
  [[ -n $burst ]] && busy+=("AWS burst node is up")
  # 5. app traffic in the last IDLE_MINUTES (chats, Pulse refreshes, any /api call except probes)
  q="sum(increase(http_requests_total{route=~\"/api/.*\",route!~\"/api/(healthz|readyz)\"}[${IDLE_MINUTES}m]))"
  hits=$(k -n monitoring exec deploy/prometheus -- wget -qO- \
         "http://localhost:9090/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$q")" 2>/dev/null \
         | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(int(float(r[0]["value"][1])) if r else 0)' 2>/dev/null)
  if [[ -z $hits ]]; then busy+=("Prometheus not answering"); elif [[ $hits -gt 0 ]]; then busy+=("$hits app requests in the last ${IDLE_MINUTES} min"); fi
fi

mkdir -p "$STATE" 2>/dev/null || true
if [[ ${#busy[@]} -gt 0 ]]; then
  [[ -z $DRY ]] && rm -f "$STATE/idle-since"
  echo "awake: ${busy[*]}"
  exit 0
fi
[[ -s $STATE/idle-since ]] || { [[ -z $DRY ]] && echo "$now" > "$STATE/idle-since"; }
since=$(cat "$STATE/idle-since" 2>/dev/null || echo "$now")
idle=$(( (now - since) / 60 ))
if [[ $idle -lt $IDLE_MINUTES ]]; then
  echo "idle for $idle of $IDLE_MINUTES min: not yet"
  exit 0
fi
wake=$(date -d "today $WAKE_AT" +%s); [[ $wake -le $((now + 300)) ]] && wake=$(date -d "tomorrow $WAKE_AT" +%s)
echo "idle for $idle min: sleeping; wakes itself at $(date -d "@$wake" '+%a %H:%M %Z')"
[[ -n $DRY ]] && exit 0

# Tell the phone (low priority) before going quiet. The topic is the alerts' ntfy secret.
topic=$(k -n monitoring get secret ntfy -o jsonpath='{.data.NTFY_TOPIC}' 2>/dev/null | base64 -d 2>/dev/null || true)
if [[ -n $topic ]]; then
  curl -fsS -m 10 -H "Title: Server sleeping" -H "Priority: 2" -H "Tags: zzz" \
    -d "Idle for $IDLE_MINUTES minutes. It wakes itself at $(date -d "@$wake" '+%H:%M %Z') for backups; wake it any time with your Wake-on-LAN app." \
    "https://ntfy.sh/$topic" >/dev/null || true
fi
logger -t qwenops-sleep "idle $idle min: suspending, RTC wake at $(date -d "@$wake" '+%F %H:%M %Z')"
rm -f "$STATE/idle-since"
rtcwake -m no -t "$wake" >/dev/null
systemctl suspend
SH
  chmod 755 "$CHECK"
}

setup() {
  need_root
  owner=${SUDO_USER:-root}
  echo "==> settings ($CONF)"
  # Rewritten if it predates SLEEP_TZ (the first version used UTC); otherwise your edits are kept.
  grep -q '^SLEEP_TZ=' "$CONF" 2>/dev/null || cat > "$CONF" <<CFG
# QwenOps sleep settings (scripts/17-sleep.sh). Times are in SLEEP_TZ.
# The backup jobs run on UTC: 08:00 IST nightly backup, 09:00 IST Sunday restore test,
# 09:45 IST off-site copy (days 1, 4, 7...). The window below keeps the server awake for all three.
SLEEP_TZ=Asia/Kolkata
IFACE=$IFACE
IDLE_MINUTES=30
KEEP_AWAKE_FROM=07:45
KEEP_AWAKE_TO=10:00
WAKE_AT=07:50
CFG
  install -d -m 2775 -o root -g "$(id -gn "$owner")" "$STATE"   # the user may set stay-awake without sudo

  echo "==> Wake-on-LAN on $IFACE (now, at every boot and before every sleep)"
  ethtool -s "$IFACE" wol g
  cat > /etc/systemd/system/qwenops-wol.service <<UNIT
[Unit]
Description=Keep Wake-on-LAN (magic packet) on for $IFACE
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s $IFACE wol g

[Install]
WantedBy=multi-user.target
UNIT
  cat > /usr/lib/systemd/system-sleep/qwenops <<HOOK
#!/bin/sh
# Before sleep: make sure the card listens for the magic packet. After: start counting idle again.
case "\$1" in
  pre)  /usr/sbin/ethtool -s $IFACE wol g ;;
  post) rm -f $STATE/idle-since; logger -t qwenops-sleep "woke up" ;;
esac
HOOK
  chmod 755 /usr/lib/systemd/system-sleep/qwenops

  echo "==> idle check every 5 minutes"
  write_check
  cat > /etc/systemd/system/qwenops-sleep.service <<'UNIT'
[Unit]
Description=QwenOps: sleep when idle (scripts/17-sleep.sh)
After=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/qwenops-idle-check
UNIT
  cat > /etc/systemd/system/qwenops-sleep.timer <<'UNIT'
[Unit]
Description=QwenOps idle check every 5 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now qwenops-wol.service qwenops-sleep.timer >/dev/null 2>&1
  echo
  ethtool "$IFACE" | grep -E "Supports Wake-on|^\s+Wake-on"
  mac=$(cat "/sys/class/net/$IFACE/address"); bcast=$(ip -o -4 addr show dev "$IFACE" | awk '{for (i = 1; i < NF; i++) if ($i == "brd") { print $(i+1); exit }}')
  cat <<MSG

Done. Phone app settings (any "Wake on LAN" app; on the home Wi-Fi):
  MAC address:        $mac
  Broadcast address:  ${bcast:-192.168.1.255}
  Port:               9
Check the decision any time: make sleep-status. Test a full cycle: make sleep-now, then wake it from the app.
BIOS: Wake-on-LAN must be on there too (Dell: F2 > Power Management > Wake on LAN > LAN Only),
and "Deep Sleep Control" off, or the card is powered down while sleeping.
MSG
}

status() {
  if [[ -x $CHECK && -s $CONF ]]; then
    echo "idle check installed: timer $(systemctl is-active qwenops-sleep.timer 2>/dev/null || true)"
    "$CHECK" --dry
  else
    echo "not set up: make sleep-setup"
  fi
  [[ -e $STATE/stay-awake ]] && echo "stay-awake switch: ON" || true
  [[ -s $CONF ]] && { . "$CONF"; echo "times in ${SLEEP_TZ:-UTC}: awake $KEEP_AWAKE_FROM-$KEEP_AWAKE_TO, wakes at $WAKE_AT"; }
  journalctl -t qwenops-sleep --since "-2 days" --no-pager -o short 2>/dev/null | tail -4 || true
}

case "${1:-}" in
  setup) setup ;;
  status) status ;;
  stay-awake) touch "$STATE/stay-awake" && echo "The server won't sleep until: make allow-sleep" ;;
  allow-sleep) rm -f "$STATE/stay-awake" && echo "Sleeping when idle again." ;;
  now)
    need_root; . "$CONF"; export TZ=${SLEEP_TZ:-UTC}
    if [[ ${2:-} =~ ^[0-9]+$ ]]; then
      wake=$(( $(date +%s) + $2 * 60 ))      # test: wake by itself after N minutes
    else
      wake=$(date -d "today $WAKE_AT" +%s); [[ $wake -le $(date +%s) ]] && wake=$(date -d "tomorrow $WAKE_AT" +%s)
    fi
    echo "Sleeping now; it wakes itself at $(date -d "@$wake" '+%a %H:%M:%S %Z'), or earlier by Wake-on-LAN."
    logger -t qwenops-sleep "manual sleep, RTC wake at $(date -d "@$wake" '+%F %H:%M:%S %Z')"
    ethtool -s "$IFACE" wol g; rtcwake -m no -t "$wake" >/dev/null; sleep 2; systemctl suspend ;;
  wol-test)
    # A: card setting. B: does the Pi's packet reach this cable (awake)? C: does it wake us (asleep)?
    need_root
    PI="${PI:-rasppi@192.168.1.104}"; user=${SUDO_USER:-root}
    pi() { sudo -u "$user" ssh -o BatchMode=yes -o ConnectTimeout=5 "$PI" "$@"; }
    echo "== A. network card"
    ethtool "$IFACE" | grep -E "Supports Wake-on|^\s+Wake-on" | sed 's/^\s*/   /'
    ethtool "$IFACE" | grep -qE "^\s+Wake-on: .*g" || { echo "   -> not set to wake on magic packet: setting it"; ethtool -s "$IFACE" wol g; }
    echo "   ACPI wake for the card: $(grep "$(basename "$(readlink -f /sys/class/net/$IFACE/device)")" /proc/acpi/wakeup | awk '{print $3}')"
    echo "== B. delivery while awake (Pi on Wi-Fi -> server on cable)"
    cap=$(mktemp); timeout 30 tcpdump -i "$IFACE" -n -l -c 1 'udp and (port 9 or port 7)' >"$cap" 2>/dev/null & tp=$!
    sleep 2; sleep 11   # waker sends at most one packet per 10 s
    pi "curl -sS -m 5 -X POST http://127.0.0.1:8081/api/wake" | sed 's/^/   Pi waker: /'
    wait $tp 2>/dev/null || true
    if [[ -s $cap ]]; then echo "   PASS  magic packet seen on $IFACE: $(head -1 "$cap" | cut -c1-110)"
    else echo "   FAIL  no magic packet reached $IFACE: the Wi-Fi->cable path drops broadcasts (router setting?)"; fi
    rm -f "$cap"
    echo "== C. real wake: Pi sends at +45, +75, +105, +135 s; fallback timer 7 min"
    pi "nohup sh -c 'sleep 45; for i in 1 2 3 4; do curl -s -m 5 -X POST http://127.0.0.1:8081/api/wake; sleep 30; done' >/dev/null 2>&1 </dev/null &"
    ethtool -s "$IFACE" wol g
    t0=$(date +%s); echo "   sleeping at $(TZ=${SLEEP_TZ:-Asia/Kolkata} date +%H:%M:%S) ..."
    rtcwake -m mem -s 420 >/dev/null 2>&1 || true      # blocks until we are awake again
    t1=$(date +%s); took=$((t1 - t0))
    echo "   awake again after $took s"
    sleep 20   # let Wi-Fi/SSH settle
    pi "journalctl -u qwenops-waker --since '-10 min' --no-pager -o cat 2>/dev/null | grep magic_packet_sent | tail -4" | sed 's/^/   Pi: /' || true
    if (( took < 400 )); then echo "   PASS  woken by Wake-on-LAN after $took s (the fallback was 420 s)"
    else echo "   FAIL  slept the full 7 minutes: the card didn't wake the PC (BIOS: Wake on LAN = LAN Only, Deep Sleep Control = Disabled)"; fi
    ;;
  remove)
    need_root
    systemctl disable --now qwenops-sleep.timer qwenops-wol.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/qwenops-sleep.{service,timer} /etc/systemd/system/qwenops-wol.service \
          /usr/lib/systemd/system-sleep/qwenops "$CHECK"
    systemctl daemon-reload; echo "Removed (settings kept in $CONF)." ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
