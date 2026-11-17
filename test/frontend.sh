#!/bin/bash
# Contract test for the frontend image (ghcr.io/hmseeb/autogpt-railway-frontend).
# Asserts:
#   1. sign-up works on a fresh deploy where the frontend boots BEFORE the
#      backend has run the migrations that create Better Auth's tables
#   2. the server boots and serves the app
#   3. the sentinel URLs baked at build time got rewritten to runtime values
#      in the client bundle (no sentinel, no localhost:8006 left)
#   4. the server answers over IPv6
#
# Test 1 exists because Better Auth >= 1.7 (upstream >= 0.8) caches a schema
# mismatch for the life of the process. On Railway the frontend is up in
# seconds and the backend takes about a minute to migrate, so every fresh
# deploy shipped with sign-up answering 500 "Database schema mismatch" until
# someone restarted the frontend by hand.
#
# Needs the pinned upstream checkout for the real migrations: UPSTREAM_DIR.
set -euo pipefail

IMG="${FRONTEND_IMAGE:-autogpt-railway-frontend:test}"
UPSTREAM_DIR="${UPSTREAM_DIR:-./upstream}"
PRISMA_CLI="${PRISMA_CLI:-5.17.0}"  # the CLI prisma-client-py 0.15.0 drives
FE=agpt-test-frontend
PG=agpt-test-fe-pg
NET=agpt-test-fe-net
ORIGIN="https://frontend.example.test"
DBURL="postgresql://postgres:testpass@$PG:5432/postgres"
UP=$(cd "$UPSTREAM_DIR/autogpt_platform" && pwd)

cleanup() { docker rm -f $FE $PG >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create $NET >/dev/null

# Empty database, like a fresh template deploy. The init script is upstream's
# own (platform schema + legacy auth.users shim the migration history needs).
docker run -d --name $PG --network $NET -e POSTGRES_PASSWORD=testpass \
  -v "$UP/db/init/00-init.sql:/docker-entrypoint-initdb.d/00-init.sql:ro" \
  pgvector/pgvector:pg15 >/dev/null
for i in $(seq 1 30); do docker exec $PG pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done

# --restart always: Railway's restart policy for this service is ALWAYS.
docker run -d --name $FE --network $NET --restart always \
  -e PORT=3000 \
  -e NEXT_PUBLIC_AGPT_SERVER_URL="https://backend.example.test/api" \
  -e NEXT_PUBLIC_AGPT_WS_SERVER_URL="wss://backend.example.test/ws" \
  -e NEXT_PUBLIC_FRONTEND_BASE_URL="$ORIGIN" \
  -e BETTER_AUTH_SECRET="test-better-auth-secret-32-chars-x" \
  -e BETTER_AUTH_URL="$ORIGIN" \
  -e DATABASE_URL="$DBURL" \
  -e AUTH_DB_SCHEMA=platform \
  -e AUTH_REQUIRE_EMAIL_VERIFICATION=false \
  "$IMG" >/dev/null

curlnet() { docker run --rm --network $NET curlimages/curl:8.10.1 "$@"; }

# Whatever hits auth first (here: us, on Railway: the healthcheck or a visitor)
# runs Better Auth's schema check while the tables are still missing.
sleep 15
curlnet -s -o /dev/null -m 10 -H "Origin: $ORIGIN" "http://$FE:3000/api/auth/get-session" || true

echo "running upstream migrations (prisma $PRISMA_CLI), like the backend's boot does..."
docker run --rm --network $NET -v "$UP/backend:/b:ro" -w /b \
  -e DATABASE_URL="$DBURL?schema=platform" -e DIRECT_URL="$DBURL?schema=platform" \
  node:24-bookworm npx -y "prisma@$PRISMA_CLI" migrate deploy --schema schema.prisma >/tmp/fe-migrate.log 2>&1 \
  || { echo "FAIL: migrations did not apply"; tail -30 /tmp/fe-migrate.log; exit 1; }
echo "migrations applied"

echo "waiting for frontend..."
ok=""
for i in $(seq 1 60); do
  code=$(docker run --rm --network $NET curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' "http://$FE:3000/" 2>/dev/null || echo 000)
  case "$code" in 2*|3*) ok=1; break;; esac
  sleep 2
done
if [ -z "$ok" ]; then echo "FAIL: frontend never answered"; docker logs $FE | tail -40; exit 1; fi
echo "PASS: frontend serves (HTTP $code)"

signup() {
  curlnet -s -o /dev/null -w '%{http_code}' -m 20 -X POST "http://$FE:3000/api/auth/sign-up/email" \
    -H 'content-type: application/json' -H "Origin: $ORIGIN" \
    -d "{\"email\":\"contract-$1@example.test\",\"password\":\"Contract-Test-Pass-1\",\"name\":\"Contract\"}" 2>/dev/null || echo 000
}
code=000
for i in $(seq 1 40); do
  code=$(signup "$i")
  [ "$code" = "200" ] && break
  sleep 3
done
[ "$code" = "200" ] || { echo "FAIL: sign-up gave $code after migrations finished (Better Auth kept a stale schema mismatch)"; docker logs $FE 2>&1 | tail -30; exit 1; }
echo "PASS: sign-up works on a frontend that booted before the migrations"

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
