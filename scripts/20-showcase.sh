#!/usr/bin/env bash
# Phase 9: the public showcase on Netlify (a static copy of the site, no backend).
#
#   ./scripts/20-showcase.sh snapshot   # save prod's Pulse, Capacity and Backups data into app-ui/showcase/
#   ./scripts/20-showcase.sh build      # build dist/ exactly as Netlify does
#   ./scripts/20-showcase.sh preview    # build, then serve dist/ on http://127.0.0.1:8088 (Ctrl+C to stop)
#
# Netlify builds from GitHub on every push to master (netlify.toml). Commit a new snapshot to refresh it.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=app-ui/showcase
CA=${CA_FILE:-certs/chatbot-local-ca.crt}
HOST=chatbot.local

get() {   # prod API, through Traefik on this machine
  curl -sf --max-time 30 --cacert "$CA" --resolve "$HOST:443:127.0.0.1" "https://$HOST$1"
}

snapshot() {
  mkdir -p "$OUT"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  for r in 15m 1h 6h; do get "/api/pulse?range=$r" > "$tmp/pulse-$r.json"; done
  get /api/capacity > "$tmp/capacity.json"
  get /api/backups > "$tmp/backups.json"
  # Keep only what the panels show, check nothing private slipped in, then replace the old snapshot.
  python3 -I - "$tmp" <<'PY'
import json, re, sys, pathlib
d = pathlib.Path(sys.argv[1])
for f in sorted(d.glob("*.json")):
    data = json.loads(f.read_text())
    if f.name.startswith(("pulse", "capacity")) and not data.get("available"):
        sys.exit(f"{f.name}: Prometheus answered 'not available'; try again in a minute")
    text = json.dumps(data, separators=(",", ":"))
    bad = re.search(r"\b(?:10|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d+\.\d+|@|AKIA|password", text)
    if bad:
        sys.exit(f"{f.name}: refusing to publish, found {bad.group(0)!r}")
    f.write_text(text + "\n")
    print(f"  {f.name}: {len(text) // 1024 + 1} KB")
PY
  date -u +'{"taken":"%Y-%m-%dT%H:%M:%SZ","from":"prod"}' > "$tmp/meta.json"
  cp "$tmp"/*.json "$OUT"/
  echo "Snapshot saved in $OUT/ ($(cat "$OUT/meta.json")). Commit it to publish."
}

build() { python3 -I scripts/netlify-build.py; }

preview() {
  build
  echo "Preview: http://127.0.0.1:8088  (Ctrl+C to stop)"
  python3 -I -m http.server 8088 --bind 127.0.0.1 --directory dist
}

case "${1:-}" in
  snapshot) snapshot ;;
  build) build ;;
  preview) preview ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
