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

exec node server.js
