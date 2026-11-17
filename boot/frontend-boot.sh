#!/bin/sh
# Rewrite the sentinel URLs baked into the Next.js build with the real
# runtime values, then start the standalone server. Idempotent: once
# rewritten the sentinels are gone and the seds match nothing.
set -e
cd /app

S_API="https://sentinel-backend.railway-template.invalid/api"
S_WS="wss://sentinel-backend.railway-template.invalid/ws"
S_BASE="https://sentinel-frontend.railway-template.invalid"

: "${NEXT_PUBLIC_AGPT_SERVER_URL:?must be set}"
: "${NEXT_PUBLIC_AGPT_WS_SERVER_URL:?must be set}"
: "${NEXT_PUBLIC_FRONTEND_BASE_URL:?must be set}"

# server.js + all server and client chunks; standalone output keeps them
# under /app. Longest sentinel first so the /api and /ws forms never
# partially match the bare base.
grep -rl "railway-template.invalid" . 2>/dev/null | while read -r f; do
  sed -i \
    -e "s|$S_API|$NEXT_PUBLIC_AGPT_SERVER_URL|g" \
    -e "s|$S_WS|$NEXT_PUBLIC_AGPT_WS_SERVER_URL|g" \
    -e "s|$S_BASE|$NEXT_PUBLIC_FRONTEND_BASE_URL|g" \
    "$f"
done

# Better Auth caches a schema mismatch for the life of the process, so do not
# serve before the backend has migrated (see wait-auth-db.mjs). Bounded to stay
# inside Railway's healthcheck window; if the backend is slower than that,
# serve anyway and restart once the migrations land, so the cache is rebuilt.
if node /opt/railway/wait-auth-db.mjs "${AUTH_DB_WAIT_SECONDS:-240}"; then
  exec node server.js
fi
echo "auth db: migrations still pending; serving now and restarting once they land" >&2
node server.js &
server=$!
if node /opt/railway/wait-auth-db.mjs 86400; then
  echo "auth db: migrations landed; restarting so Better Auth re-checks its schema" >&2
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  exit 1
fi
wait "$server"
