#!/usr/bin/env bash
# Lint + unit tests in throwaway containers (no Python/Postgres needed on the host).
# Proves the 50-user / 15-chat rules against a real Postgres.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=chatbot-test-$$
cleanup() { docker rm -f "pg-$NET" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker network create "$NET" >/dev/null
docker run -d --name "pg-$NET" --network "$NET" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=test postgres:16-alpine >/dev/null
until docker exec "pg-$NET" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
sleep 2

docker run --rm --network "$NET" -v "$PWD/app-chat:/src:ro" -w /src \
  -e DATABASE_URL="postgresql://postgres:test@pg-$NET:5432/test" \
  -e SESSION_SECRET="test-secret-test-secret-test-secret-123" \
  -e PYTHONDONTWRITEBYTECODE=1 \
  python:3.12-slim sh -c "pip install -q -r requirements-dev.txt && ruff check --no-cache app tests && python -m pytest -q -p no:cacheprovider tests"
