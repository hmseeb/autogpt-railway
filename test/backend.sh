#!/bin/bash
# Contract test for the backend image (ghcr.io/hmseeb/autogpt-railway-backend).
# Asserts the Railway-shaped behaviors the template depends on:
#   1. migrations run on boot against a fresh postgres
#   2. the REST API answers on the muxed $PORT
#   3. the websocket path /ws upgrades on the same muxed $PORT
#   4. the muxed port answers over IPv6 (Railway healthchecks + private net)
#   5. a hex ENCRYPTION_KEY is accepted (boot derives the fernet key)
#   6. BACKEND_CORS_ALLOW_ORIGINS is honored: the configured frontend origin
#      passes preflight and an unlisted one does not
#
# Test 6 exists because shipping without that variable broke the copilot chat on
# every deploy while leaving the healthcheck green: the chat is the only surface
# that calls the backend directly from the browser, so its preflight 400'd and
# the user saw "Connection lost" with nothing in the logs. If a future upstream
# release renames or drops the setting, the accepted-origin assertion fails here
# instead of in production.
set -euo pipefail

IMG="${BACKEND_IMAGE:-autogpt-railway-backend:test}"
NET=agpt-test-net
PG=agpt-test-pg
RD=agpt-test-redis
RB=agpt-test-rabbit
BE=agpt-test-backend

cleanup() { docker rm -f $PG $RD $RB $BE >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker network create $NET >/dev/null

docker run -d --name $PG --network $NET \
  -e POSTGRES_PASSWORD=testpass -e PGDATA=/var/lib/postgresql/data/pgdata \
  pgvector/pgvector:pg15 >/dev/null

# single-node redis cluster, same start command the template uses
docker run -d --name $RD --network $NET redis:7 /bin/sh -c \
  "redis-server --port 6379 --cluster-enabled yes --cluster-config-file /tmp/nodes.conf --cluster-require-full-coverage no --cluster-announce-hostname $RD --cluster-preferred-endpoint-type hostname --protected-mode no & until redis-cli -p 6379 ping >/dev/null 2>&1; do sleep 1; done; redis-cli -p 6379 cluster addslotsrange 0 16383 || true; wait" >/dev/null

docker run -d --name $RB --network $NET \
  -e RABBITMQ_DEFAULT_USER=rabbituser -e RABBITMQ_DEFAULT_PASS=rabbitpass \
  rabbitmq:4.1.4 >/dev/null

echo "waiting for postgres..."
for i in $(seq 1 30); do
  docker exec $PG pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 2
done

HEXKEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")

docker run -d --name $BE --network $NET \
  -e PORT=8080 \
  -e DB_HOST=$PG -e DB_PORT=5432 -e DB_USER=postgres -e DB_PASS=testpass -e DB_NAME=postgres \
  -e DATABASE_URL="postgresql://postgres:testpass@$PG:5432/postgres?connect_timeout=60&schema=platform" \
  -e DIRECT_URL="postgresql://postgres:testpass@$PG:5432/postgres?connect_timeout=60&schema=platform" \
  -e REDIS_HOST=$RD -e REDIS_PORT=6379 \
  -e RABBITMQ_HOST=$RB -e RABBITMQ_PORT=5672 \
  -e RABBITMQ_DEFAULT_USER=rabbituser -e RABBITMQ_DEFAULT_PASS=rabbitpass \
  -e ENCRYPTION_KEY="$HEXKEY" \
  -e UNSUBSCRIBE_SECRET_KEY="$HEXKEY" \
  -e JWT_VERIFY_KEY="test-jwt-verify-key-at-least-32-characters-long" \
  -e JWT_JWKS_URL="https://frontend-not-running-in-this-test.invalid/api/auth/jwks" \
  -e CLAMAV_SERVICE_ENABLED=false \
  -e BACKEND_CORS_ALLOW_ORIGINS='["https://frontend-under-test.invalid"]' \
  "$IMG" >/dev/null

echo "waiting for backend on muxed port..."
ok=""
for i in $(seq 1 150); do
  if docker run --rm --network $NET curlimages/curl:8.10.1 -fsS -o /dev/null "http://$BE:8080/health" 2>/dev/null; then ok=1; break; fi
  sleep 2
done
if [ -z "$ok" ]; then echo "FAIL: REST API never answered on muxed port"; docker logs $BE 2>&1 | tail -200; exit 1; fi
echo "PASS: REST API on muxed \$PORT"

# migrations actually landed
TABLES=$(docker exec $PG psql -U postgres -tAc "select count(*) from information_schema.tables where table_schema='platform'")
[ "$TABLES" -gt 10 ] || { echo "FAIL: platform schema has $TABLES tables, migrations did not run"; exit 1; }
echo "PASS: migrations ran ($TABLES tables in platform schema)"

# websocket upgrade on the same port
WS=$(docker run --rm --network $NET curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' \
  -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" "http://$BE:8080/ws")
[ "$WS" = "101" ] || [ "$WS" = "403" ] || [ "$WS" = "401" ] || { echo "FAIL: /ws gave $WS, not an upgrade or an auth challenge"; exit 1; }
echo "PASS: /ws reaches the websocket server (HTTP $WS)"

# IPv6: the muxed port must answer on v6 (Railway dials containers over v6)
V6=$(docker exec $BE /bin/sh -c "command -v curl >/dev/null && curl -s -o /dev/null -w '%{http_code}' 'http://[::1]:8080/health' || echo curl-missing")
[ "$V6" = "200" ] || { echo "FAIL: IPv6 loopback gave $V6"; exit 1; }
echo "PASS: muxed port answers over IPv6"

# CORS allowlist. The middleware answers preflight before routing, so the path
# only has to exist as far as the muxer; /health is the stable one.
preflight() {
  docker run --rm --network $NET curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' \
    -X OPTIONS -H "Origin: $1" -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: content-type,authorization" \
    "http://$BE:8080/health"
}
ALLOWED=$(preflight "https://frontend-under-test.invalid")
[ "$ALLOWED" = "200" ] || { echo "FAIL: configured origin got $ALLOWED, expected 200 - BACKEND_CORS_ALLOW_ORIGINS not honored"; exit 1; }
echo "PASS: configured frontend origin passes preflight"

DENIED=$(preflight "https://not-the-frontend.invalid")
[ "$DENIED" != "200" ] || { echo "FAIL: unlisted origin passed preflight, allowlist is not being enforced"; exit 1; }
echo "PASS: unlisted origin rejected (HTTP $DENIED)"

echo "ALL BACKEND CONTRACT TESTS PASS"
