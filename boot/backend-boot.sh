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

# Provider routing. The deployer pastes ONE credential and the matching mode
# switch is derived here, rather than being a second field they must remember.
# A Railway template form cannot express "and also set this other flag", so the
# alternative was a hidden switch defaulting to off, which silently ignored a
# pasted Claude token: worse than having no field at all.
#
# Precedence mirrors upstream's own effective_transport (config.py): local,
# then subscription, then openrouter, then direct anthropic. An explicitly set
# switch always wins over the derived one, so any non-default combination is
# still reachable by setting both by hand.
if [ -n "${OPEN_ROUTER_API_KEY:-}${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}${CHAT_BASE_URL:-}${CHAT_API_KEY:-}" ]; then
  if [ -n "${CHAT_BASE_URL:-}" ] && [ -z "${CHAT_USE_LOCAL:-}" ]; then
    export CHAT_USE_LOCAL=true
    echo "provider: custom OpenAI-compatible endpoint (${CHAT_BASE_URL})"
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${CHAT_USE_CLAUDE_CODE_SUBSCRIPTION:-}" ]; then
    export CHAT_USE_CLAUDE_CODE_SUBSCRIPTION=true
    echo "provider: Claude subscription (setup-token)"
  elif [ -n "${OPEN_ROUTER_API_KEY:-}" ] && [ -z "${CHAT_USE_CLAUDE_CODE_SUBSCRIPTION:-}" ]; then
    echo "provider: OpenRouter"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CHAT_USE_OPENROUTER:-}" ]; then
    export CHAT_USE_OPENROUTER=false
    echo "provider: Anthropic direct"
  else
    echo "provider: using the CHAT_USE_* switches set on this service"
  fi
  # The copilot's web_search tool calls perplexity/sonar through whatever
  # CHAT_API_KEY + CHAT_BASE_URL point at, and marketplace search needs an
  # embedding client, neither of which the chat transport provides. The
  # subscription and local transports have an EMPTY api_key fallback chain
  # (config.py _TRANSPORT_PROFILES), so OPEN_ROUTER_API_KEY alone never
  # reaches them: it has to be CHAT_API_KEY. Bridge it here so one pasted
  # OpenRouter key lights up search on every route rather than just its own.
  # Skipped when CHAT_BASE_URL is set, since that key belongs to that endpoint.
  if [ -n "${OPEN_ROUTER_API_KEY:-}" ] && [ -z "${CHAT_API_KEY:-}" ] && [ -z "${CHAT_BASE_URL:-}" ]; then
    export CHAT_API_KEY="$OPEN_ROUTER_API_KEY"
    echo "web search + marketplace search: enabled via OpenRouter"
  elif [ -z "${OPEN_ROUTER_API_KEY:-}${CHAT_API_KEY:-}" ]; then
    echo "NOTE: no OpenRouter credential, so the assistant's web search and"
    echo "      marketplace search will report themselves unavailable. The"
    echo "      chat itself works. Add OPEN_ROUTER_API_KEY to enable both;"
    echo "      it can sit alongside the provider you already configured."
  fi
else
  echo "=============================================================="
  echo "NO CHAT PROVIDER CONFIGURED. The platform will start and agents"
  echo "you build will run, but the built-in chat assistant will answer"
  echo "every message with an error until you set ONE of these on this"
  echo "service and redeploy:"
  echo "  OPEN_ROUTER_API_KEY       openrouter.ai/keys (also powers search)"
  echo "  ANTHROPIC_API_KEY         console.anthropic.com"
  echo "  CLAUDE_CODE_OAUTH_TOKEN   run: claude setup-token"
  echo "  CHAT_BASE_URL + CHAT_API_KEY   your own OpenAI-compatible endpoint"
  echo "=============================================================="
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

# Marketplace skills + expert roster. Upstream compose runs this as a one-shot
# right after migrate, with nothing waiting on it; idempotent, best effort
# (it reads the public catalog from GitHub). Kept OUT of the pid list below,
# so its normal exit does not take the long-running services down.
if [ "${AUTOGPT_PUBLISH_SKILLS:-1}" = "1" ]; then
  (
    if timeout 600 publish-skills-catalog --skip-missing-preloads; then
      echo "skills catalog published"
    else
      echo "WARNING: skills catalog publish failed (see above); continuing without it" >&2
    fi
  ) &
fi

# Same processes upstream's production compose runs, one per line.
# db (DatabaseManager) first: the others RPC through it.
# If any process dies the container exits and Railway (ALWAYS) restarts it.
pids=()
db & pids+=($!); sleep 3
executor & pids+=($!)
copilot-executor & pids+=($!)
ws & pids+=($!)
scheduler & pids+=($!)
notification & pids+=($!)
platform-linking-manager & pids+=($!)
rest & pids+=($!)
wait -n "${pids[@]}"
echo "a backend process exited; restarting container" >&2
exit 1
