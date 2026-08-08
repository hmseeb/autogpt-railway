# Deploy and Host AutoGPT Platform on Railway

AutoGPT Platform is the agent builder from the AutoGPT team. You visually compose AI agents from blocks, wire them to LLM providers and integrations, run them on schedules or triggers, and watch executions live. This template deploys the full self-hosted platform: frontend, the complete backend stack, postgres with vector search, redis, and rabbitmq.

## About Hosting AutoGPT Platform

Hosting AutoGPT Platform means running five coordinated pieces: a Next.js frontend with embedded auth, a Python backend that bundles the REST API, websocket server, agent executor, scheduler and notification workers in one container, a postgres database with the vector extension, a redis cluster for caching and events, and rabbitmq for the execution queue. This template wires all of it: database migrations run automatically on boot, secrets are generated per deploy, the API and websocket traffic share one public endpoint, and agent workspace files persist on a volume. Keys go in two separate places. The built in chat assistant runs on one key you set on the backend service at deploy time, with OpenRouter, Anthropic, your own Claude Pro or Max subscription, or a self hosted model all supported. The agents you build in the visual editor use per user keys that each account adds inside the app under Settings.

## Common Use Cases

- Personal AI agent workbench: build agents that research, summarize, and post on schedules you control
- Automation backend for a team, with each member registering their own account and credentials
- A private alternative to hosted agent platforms when your prompts and data must stay on infrastructure you control

## Dependencies for AutoGPT Platform Hosting

### Deployment Dependencies

- One credential at deploy time to power the chat assistant, whichever suits you: an OpenRouter API key (which also powers marketplace search), an Anthropic API key, a token from your own Claude Pro or Max subscription, or the address and key of any OpenAI compatible endpoint you already run. Fill in one and the matching mode turns itself on. Leave them all blank and everything still deploys; the chat then replies with an error naming the setting it wants, and you can add it later.
- An LLM provider API key per user, added inside the app after signup, for the blocks your agents are built from
- Optional: OAuth client credentials for any integration you want to connect by sign in rather than by API key (GitHub, Google, Notion, Reddit, Discord, Twitter or X, Linear, Todoist). You register an app with that provider, point its callback at your own deployed address, and add the id and secret pair to the backend service. Integrations that take a plain API key need none of this and work as soon as a user pastes their key in the app. The readme lists the variable names and the callback URL.

### Implementation Details

The backend image is built from the pinned upstream release autogpt-platform-beta-v0.7.0 and runs all backend processes in one container, launching the same per service commands upstream's own production compose file runs. Database migrations apply automatically on every boot before the app starts. The backend trusts the frontend's generated domain as a caller, which the chat assistant needs because it talks to the backend directly from the browser rather than through the frontend. The REST API and the websocket server are served through a single public endpoint, with websocket traffic routed by path. Redis runs in single node cluster mode because the backend's cache client speaks cluster protocol only. Virus scanning of uploads is off by default to keep the footprint small; set CLAMAV_SERVICE_ENABLED to true and add a ClamAV service if you need it.

## Why Deploy AutoGPT Platform on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying AutoGPT Platform on Railway, you are one click away from a private agent building platform with zero yaml, zero manual migrations, and every credential generated for you. Paste one provider key at deploy time, sign up, and your first agent is running in minutes.
