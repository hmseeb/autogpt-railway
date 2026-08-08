#!/bin/bash
# Contract test for the backend image (ghcr.io/hmseeb/autogpt-railway-backend).
# Asserts the Railway-shaped behaviors the template depends on:
#   1. migrations run on boot against a fresh postgres
#   2. the REST API answers on the muxed $PORT
#   3. the websocket path /ws upgrades on the same muxed $PORT
#   4. the muxed port answers over IPv6 (Railway healthchecks + private net)
#   5. a hex ENCRYPTION_KEY is accepted (boot derives the fernet key)
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
  -e JWT_JWKS_URL="" \
  -e CLAMAV_SERVICE_ENABLED=false \
  "$IMG" >/dev/null

echo "waiting for backend on muxed port..."
ok=""
for i in $(seq 1 90); do
  if docker run --rm --network $NET curlimages/curl:8.10.1 -fsS -o /dev/null "http://$BE:8080/health" 2>/dev/null; then ok=1; break; fi
  sleep 2
done
if [ -z "$ok" ]; then echo "FAIL: REST API never answered on muxed port"; docker logs $BE | tail -40; exit 1; fi
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

echo "ALL BACKEND CONTRACT TESTS PASS"
