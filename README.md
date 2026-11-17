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

The two ghcr images are thin overlays on the pinned upstream release `autogpt-platform-beta-v0.11.3`, built by CI in this repo. See `Dockerfile.backend`, `Dockerfile.frontend`, and `boot/` for exactly what they add. `template.json` is the full build sheet with rationale per choice.

## First run

1. Deploy. Set `OPEN_ROUTER_API_KEY` at the prompt if you want the chat assistant working from the first message; it can also be added later. First boot takes a few minutes: postgres initializes, backend applies migrations, frontend rewrites its baked URLs.
2. Open the frontend URL, create an account (first account is a normal user; registration is open, this is your private instance).
3. Open the chat and send a message.
4. Build an agent in the builder, run it. Blocks that call an LLM need credentials added under Settings, per user.

## Two separate places keys go

This trips everyone up, so it is worth being explicit.

**The chat assistant** is powered by credentials on the `backend` service, set by whoever deploys. Nothing in the app's Settings page affects it.

**Start with `OPEN_ROUTER_API_KEY`.** It is the only single credential that gives you a complete assistant, because two features are wired to OpenRouter regardless of which model answers your messages:

- **Web search.** The assistant's search tool calls `perplexity/sonar` through OpenRouter. Without it, asking the assistant to look something up returns "Web search is unavailable".
- **Marketplace search**, which needs an embedding model.

The other three routes choose which model *writes the replies*. They do not provide either of the above:

| Route | Set on `backend` | Covers |
|---|---|---|
| OpenRouter | `OPEN_ROUTER_API_KEY` | chat, web search, marketplace search |
| Your own Claude Pro/Max subscription | `CLAUDE_CODE_OAUTH_TOKEN`, from `claude setup-token` | chat only |
| Your own OpenAI-compatible endpoint | `CHAT_BASE_URL` and `CHAT_API_KEY` | chat only |

**These combine.** Want Claude answering your messages but working search? Set `CLAUDE_CODE_OAUTH_TOKEN` *and* `OPEN_ROUTER_API_KEY`. The boot script routes the chat to your subscription and search to OpenRouter, and prints which it picked.

The boot script turns on the matching mode for whichever credential you filled, so there is no second flag to remember. Setting a mode switch by hand (`CHAT_USE_OPENROUTER`, `CHAT_USE_CLAUDE_CODE_SUBSCRIPTION`, `CHAT_USE_LOCAL`) always overrides what it picked.

An Anthropic key does not power the chat: with only `ANTHROPIC_API_KEY` set, upstream refuses every message with "No API key configured" (its check wants `OPEN_ROUTER_API_KEY` or `CHAT_API_KEY`). Put an Anthropic key in the app under Settings > Credentials instead, where agent blocks such as AI Text Generator use it.

With nothing set the platform still deploys and agents you build still run; only the chat is affected, and it replies with an error naming what it wants. The deploy logs list the options too.

The subscription route is for a personal instance. A Claude consumer subscription is not licensed to serve other people, so do not use it on an instance you open up to others. A `claude setup-token` token works on its own; you do not need a refresh token.

**Agent blocks** are the opposite: each user adds their own provider keys inside the app under Settings, and those only feed the blocks wired up in the builder.

## Connecting integrations (Reddit, GitHub, Google, ...)

Settings, Integrations, Connect Service works for some providers immediately and fails for others with:

> Integration with provider 'x' is not configured. Set client ID and secret in the application's deployment environment

That message is correct but tells you neither the variable names nor the callback URL. Both are below.

There are two kinds of integration and only one needs you to do anything:

**Key-based** (most of them): each user pastes their own API key inside the app when a block asks for it. Nothing to configure at deploy time, works out of the box.

**OAuth-based** (the Connect Service button): needs *you*, the person who deployed, to register an application with that provider first. This is unavoidable. OAuth identifies the application, not the user, so there is no way to ship working credentials in a public template, and no way for the app to invent them.

To enable one:

1. Create an app in that provider's developer console
2. Register this callback URL, using your own frontend address:
   `https://<your-frontend-domain>/auth/integrations/oauth_callback`
3. Add the pair to the `backend` service and redeploy

Every OAuth provider in `autogpt-platform-beta-v0.11.3`:

| Provider | Variables |
|---|---|
| GitHub | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` |
| Google | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` |
| Notion | `NOTION_CLIENT_ID`, `NOTION_CLIENT_SECRET` |
| Reddit | `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET` |
| Discord | `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET` |
| Twitter / X | `TWITTER_CLIENT_ID`, `TWITTER_CLIENT_SECRET` |
| Linear | `LINEAR_CLIENT_ID`, `LINEAR_CLIENT_SECRET` |
| Todoist | `TODOIST_CLIENT_ID`, `TODOIST_CLIENT_SECRET` |
| Airtable | `AIRTABLE_CLIENT_ID`, `AIRTABLE_CLIENT_SECRET` |
| WordPress | `WORDPRESS_CLIENT_ID`, `WORDPRESS_CLIENT_SECRET` |
| HubSpot | `HUBSPOT_CLIENT_ID`, `HUBSPOT_CLIENT_SECRET` |
| Microsoft | `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET` (optional `MICROSOFT_TENANT_ID`) |

Add only the ones you actually want. Each is independent, and the rest keep working as before. The backend logs a line at startup for any provider that implements OAuth without both variables set, which is a quick way to see what is currently missing.

That table is not maintained by hand. `test/oauth-providers.py` extracts the list from the pinned upstream source across both registration paths, and CI fails the build if the readme drifts, so a release that adds a provider cannot ship undocumented. Run `python3 test/oauth-providers.py --upstream ./upstream` to print the current set.

The naming rule, for reference: `<PROVIDER>_CLIENT_ID` and `<PROVIDER>_CLIENT_SECRET`, which is what upstream's own registration helper defaults to.

Two things this section does not cover, because neither uses deployment variables:

- **MCP servers** authenticate per server, set up inside the app rather than here
- **Key-based integrations** need nothing from you at all; the user pastes their own key when a block asks for it

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

If the bump fails on the OAuth provider check, upstream added or removed an integration. Run `python3 test/oauth-providers.py --upstream ./upstream` and update the readme table to match; that is the intended workflow, not a reason to skip the check.
