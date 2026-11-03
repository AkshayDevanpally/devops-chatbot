#!/usr/bin/env bash
# Prints the current digest of each base/third-party image so you can pin them
# (FROM image@sha256:...) - a tag can be re-pointed, a digest can't.
set -euo pipefail
for img in python:3.12-slim nginxinc/nginx-unprivileged:1.27-alpine postgres:16-alpine ollama/ollama:0.30.10 busybox:1.36; do
  digest=$(docker buildx imagetools inspect "$img" --format '{{json .Manifest}}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["digest"])')
  echo "$img@$digest"
done
