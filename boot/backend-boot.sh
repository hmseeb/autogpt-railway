#!/bin/bash
# Boot for the Railway backend service:
# keys -> migrations -> caddy mux -> the 8 upstream service processes.
#
# NOT the upstream `app` monolith entrypoint: on Linux it forks children
# from a parent that already holds prisma/redis threads and deadlocks
# silently (fork-with-threads; upstream devs use macOS where the default
# start method is spawn, and their production compose runs per-service
# commands, never `app`). We run the same per-service commands compose
# runs, in one container because they share the workspace volume.
set -e

# Railway's ${{secret(64, "0123456789abcdef")}} gives hex; the app wants
# fernet keys (urlsafe base64 of 32 bytes). Derive deterministically so
# the same template variable always yields the same key.
derive_fernet() {
  python3 -c "import base64,sys;print(base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).decode())" "$1"
}
if echo "$ENCRYPTION_KEY" | grep -qE '^[0-9a-fA-F]{64}$'; then
  ENCRYPTION_KEY=$(derive_fernet "$ENCRYPTION_KEY"); export ENCRYPTION_KEY
fi
if echo "$UNSUBSCRIBE_SECRET_KEY" | grep -qE '^[0-9a-fA-F]{64}$'; then
  UNSUBSCRIBE_SECRET_KEY=$(derive_fernet "$UNSUBSCRIBE_SECRET_KEY"); export UNSUBSCRIBE_SECRET_KEY
fi

# Prisma migrations. The server image ships the prisma CLI in its venv.
# Retry: on a fresh template deploy postgres may still be initializing.
cd /app/autogpt_platform/backend
tries=0
until prisma migrate deploy; do
  tries=$((tries + 1))
  [ "$tries" -ge 30 ] && { echo "migrations failed after 30 attempts"; exit 1; }
  echo "migrate attempt $tries failed, retrying in 5s..."
  sleep 5
done

caddy start --config /etc/caddy/Caddyfile

# Same processes upstream's production compose runs, one per line.
# db (DatabaseManager) first: the others RPC through it.
# If any process dies the container exits and Railway (ALWAYS) restarts it.
db & sleep 3
executor &
copilot-executor &
ws &
scheduler &
notification &
platform-linking-manager &
rest &
wait -n
echo "a backend process exited; restarting container" >&2
exit 1
