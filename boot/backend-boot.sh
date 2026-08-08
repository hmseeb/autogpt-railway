#!/bin/sh
# Boot for the Railway backend service. Order matters:
# keys -> migrations -> caddy mux -> app monolith (foreground).
set -e

# Railway's ${{secret(64, "0123456789abcdef")}} gives hex; the app wants
# fernet keys (urlsafe base64 of 32 bytes). Derive deterministically so
# the same template variable always yields the same key.
derive_fernet() {
  python3 -c "import base64,sys;print(base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).decode())" "$1"
}
case "$ENCRYPTION_KEY" in
  ????????????????????????????????????????????????????????????????)
    if echo "$ENCRYPTION_KEY" | grep -qE '^[0-9a-fA-F]{64}$'; then
      ENCRYPTION_KEY=$(derive_fernet "$ENCRYPTION_KEY"); export ENCRYPTION_KEY
    fi ;;
esac
case "$UNSUBSCRIBE_SECRET_KEY" in
  ????????????????????????????????????????????????????????????????)
    if echo "$UNSUBSCRIBE_SECRET_KEY" | grep -qE '^[0-9a-fA-F]{64}$'; then
      UNSUBSCRIBE_SECRET_KEY=$(derive_fernet "$UNSUBSCRIBE_SECRET_KEY"); export UNSUBSCRIBE_SECRET_KEY
    fi ;;
esac

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

exec app
