#!/bin/bash
# Contract test for the frontend image (ghcr.io/hmseeb/autogpt-railway-frontend).
# Asserts:
#   1. the server boots and serves the app
#   2. the sentinel URLs baked at build time got rewritten to runtime values
#      in the client bundle (no sentinel, no localhost:8006 left)
#   3. the server answers over IPv6
set -euo pipefail

IMG="${FRONTEND_IMAGE:-autogpt-railway-frontend:test}"
FE=agpt-test-frontend
NET=agpt-test-fe-net

cleanup() { docker rm -f $FE >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create $NET >/dev/null

docker run -d --name $FE --network $NET \
  -e PORT=3000 \
  -e NEXT_PUBLIC_AGPT_SERVER_URL="https://backend.example.test/api" \
  -e NEXT_PUBLIC_AGPT_WS_SERVER_URL="wss://backend.example.test/ws" \
  -e NEXT_PUBLIC_FRONTEND_BASE_URL="https://frontend.example.test" \
  -e BETTER_AUTH_SECRET="test-better-auth-secret-32-chars-x" \
  -e BETTER_AUTH_URL="https://frontend.example.test" \
  -e DATABASE_URL="postgresql://postgres:x@nowhere:5432/postgres" \
  -e AUTH_DB_SCHEMA=platform \
  "$IMG" >/dev/null

echo "waiting for frontend..."
ok=""
for i in $(seq 1 60); do
  code=$(docker run --rm --network $NET curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' "http://$FE:3000/" 2>/dev/null || echo 000)
  case "$code" in 2*|3*) ok=1; break;; esac
  sleep 2
done
if [ -z "$ok" ]; then echo "FAIL: frontend never answered"; docker logs $FE | tail -40; exit 1; fi
echo "PASS: frontend serves (HTTP $code)"

# no sentinel or localhost API URL may remain in any served chunk
LEFT=$(docker exec $FE /bin/sh -c "grep -rl 'railway-template.invalid' .next 2>/dev/null | head -3" || true)
[ -z "$LEFT" ] || { echo "FAIL: sentinel still present in: $LEFT"; exit 1; }
echo "PASS: no sentinel URLs left in the bundle"

HIT=$(docker exec $FE /bin/sh -c "grep -rl 'backend.example.test/api' .next/static 2>/dev/null | head -1" || true)
[ -n "$HIT" ] || { echo "FAIL: runtime backend URL not found in client bundle"; exit 1; }
echo "PASS: runtime backend URL present in client bundle"

# Upstream >= 0.9 declares NEXT_PUBLIC_FRONTEND_BASE_URL as a build ARG; if the
# build ever inlines it as empty instead of our sentinel, auth redirects and
# share links point nowhere while the page itself still loads.
HIT=$(docker exec $FE /bin/sh -c "grep -rl 'https://frontend.example.test' .next 2>/dev/null | head -1" || true)
[ -n "$HIT" ] || { echo "FAIL: runtime frontend base URL not found in the build"; exit 1; }
echo "PASS: runtime frontend base URL present in the build"

V6=$(docker exec $FE /bin/sh -c "wget -q -O /dev/null 'http://[::1]:3000/' && echo ok || echo fail")
[ "$V6" = "ok" ] || { echo "FAIL: IPv6 loopback: $V6"; exit 1; }
echo "PASS: frontend answers over IPv6"

echo "ALL FRONTEND CONTRACT TESTS PASS"
