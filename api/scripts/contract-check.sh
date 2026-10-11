#!/bin/sh
# Runs web/'s read API contract test (web/src/api/contract.test.ts) against this API.
# CI (.github/workflows/api.yml) and a local run (api/README.md) both call this script.
#
# Needs: DATABASE_URL on a database migrated and seeded as in db/README.md, and `npm ci` already
# run in api/ and web/. CONTRACT_PORT picks the API's port (default 8080). DATABASE_URL is passed
# to the API only and never printed.
set -eu

: "${DATABASE_URL:?DATABASE_URL must point at a migrated, seeded database}"
root=$(cd "$(dirname "$0")/../.." && pwd)
port=${CONTRACT_PORT:-8080}
log=$(mktemp)
pid=

finish() {
  status=$?
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  if [ "$status" -ne 0 ]; then
    echo "== api log"
    cat "$log"
  fi
  rm -f "$log"
  exit "$status"
}
trap finish EXIT INT TERM

echo "== start the API on port $port"
# node --import tsx keeps the server one process, so the kill above stops it.
(cd "$root/api" && PORT="$port" exec node --import tsx src/server.ts) >"$log" 2>&1 &
pid=$!

i=0
until curl -sf "http://localhost:$port/api/health" >/dev/null; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "the API exited before answering /api/health"
    exit 1
  fi
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "the API did not answer /api/health within 30 seconds"
    exit 1
  fi
  sleep 0.5
done

echo "== web contract test against http://localhost:$port/api"
CONTRACT_API_URL="http://localhost:$port/api" npm --prefix "$root/web" test
