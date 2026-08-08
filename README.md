# AutoGPT Platform on Railway

Click to deploy AutoGPT Platform (the agent builder, not the retired 2023 script) on Railway. Community template, not an official AutoGPT build.

## What deploys

| Service | Image | Persists |
|---|---|---|
| frontend | ghcr.io/hmseeb/autogpt-railway-frontend | no |
| backend | ghcr.io/hmseeb/autogpt-railway-backend | agent workspace volume |
| postgres | pgvector/pgvector:pg15 | volume |
| redis | redis:7, single node cluster mode | no, cache only |
| rabbitmq | rabbitmq:4.1.4 | volume |

The two ghcr images are thin overlays on the pinned upstream release `autogpt-platform-beta-v0.7.0`, built by CI in this repo. See `Dockerfile.backend`, `Dockerfile.frontend`, and `boot/` for exactly what they add. `template.json` is the full build sheet with rationale per choice.

## First run

1. Deploy. Set `OPEN_ROUTER_API_KEY` at the prompt if you want the chat assistant working from the first message; it can also be added later. First boot takes a few minutes: postgres initializes, backend applies migrations, frontend rewrites its baked URLs.
2. Open the frontend URL, create an account (first account is a normal user; registration is open, this is your private instance).
3. Open the chat and send a message.
4. Build an agent in the builder, run it. Blocks that call an LLM need credentials added under Settings, per user.

## Two separate places keys go

This trips everyone up, so it is worth being explicit.

**The chat assistant** is powered by one credential on the `backend` service, set by whoever deploys. Nothing in the app's Settings page affects it. Fill in exactly one of these four at deploy time:

| Route | Set on `backend` |
|---|---|
| OpenRouter (recommended, also powers marketplace search) | `OPEN_ROUTER_API_KEY` |
| Anthropic direct | `ANTHROPIC_API_KEY` |
| Your own Claude Pro/Max subscription | `CLAUDE_CODE_OAUTH_TOKEN`, from running `claude setup-token` |
| Your own OpenAI-compatible endpoint, incl. an OpenAI key | `CHAT_BASE_URL` and `CHAT_API_KEY` |

One credential is all you need. The boot script turns on the matching mode for whichever you filled, so there is no second flag to remember. If you want an unusual combination, setting a mode switch by hand (`CHAT_USE_OPENROUTER`, `CHAT_USE_CLAUDE_CODE_SUBSCRIPTION`, `CHAT_USE_LOCAL`) always overrides what the boot script picked.

With none of them set the platform still deploys and agents you build still run; only the chat is affected, and it replies with an error naming what it wants. The deploy logs list the options too.

The subscription route is for a personal instance. A Claude consumer subscription is not licensed to serve other people, so do not use it on an instance you open up to others. It also only covers the chat, not marketplace search. A `claude setup-token` token works on its own; you do not need a refresh token.

**Agent blocks** are the opposite: each user adds their own provider keys inside the app under Settings, and those only feed the blocks wired up in the builder.

## Using your own domain

**Read this before you point a custom domain at the frontend, or the chat will break.**

The chat is the one screen that calls the backend directly from the browser instead of going through the frontend. The backend only accepts calls from origins listed in `BACKEND_CORS_ALLOW_ORIGINS`, which the template fills in with the frontend's generated `*.up.railway.app` address. Your own domain is not in that list, so the browser's permission check fails and the chat shows "Connection lost, reconnecting" with no explanation. Every other screen keeps working, which makes it look like something else.

Fix it by editing `BACKEND_CORS_ALLOW_ORIGINS` on the `backend` service to include your domain. It is a JSON array of full origins, scheme included, no trailing slash:

```
["https://agents.example.com","https://${{frontend.RAILWAY_PUBLIC_DOMAIN}}"]
```

While you are there, point `FRONTEND_BASE_URL` on the backend and `BETTER_AUTH_URL` plus `NEXT_PUBLIC_FRONTEND_BASE_URL` on the frontend at the same domain, or sign-in redirects and OAuth callbacks keep sending people back to the old address.

## Notes

- Virus scanning of uploads is disabled (`CLAMAV_SERVICE_ENABLED=false`). Add a ClamAV service and flip it if you need upload scanning.
- The knowledge graph memory feature (FalkorDB) is not deployed; upstream gates it behind a feature flag that self-host builds don't see.
- Upstream license for the platform is PolyForm Shield. Self-hosting for your own use is what this template does; do not resell it as a competing hosted service.

## Regenerating

Contract tests in `test/` run in CI before any image is pushed. To bump the upstream version: change `UPSTREAM_TAG` in `.github/workflows/build.yml` and the two image tags in `template.json`, push, wait for green, then redeploy services.
