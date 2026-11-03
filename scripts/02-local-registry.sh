#!/usr/bin/env bash
# Private image registry on localhost:5000 (bound to 127.0.0.1, so not reachable from the LAN).
set -euo pipefail

if docker ps -a --format '{{.Names}}' | grep -qx registry; then
  docker start registry >/dev/null
else
  docker run -d --name registry --restart=always \
    -p 127.0.0.1:5000:5000 \
    -v registry-data:/var/lib/registry \
    --security-opt no-new-privileges:true \
    registry:2
fi
curl -sf http://localhost:5000/v2/ >/dev/null && echo "registry is up on localhost:5000"
