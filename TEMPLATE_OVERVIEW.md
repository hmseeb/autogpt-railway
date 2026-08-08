# Deploy and Host AutoGPT Platform on Railway

AutoGPT Platform is the agent builder from the AutoGPT team. You visually compose AI agents from blocks, wire them to LLM providers and integrations, run them on schedules or triggers, and watch executions live. This template deploys the full self-hosted platform: frontend, the complete backend stack, postgres with vector search, redis, and rabbitmq.

## About Hosting AutoGPT Platform

Hosting AutoGPT Platform means running five coordinated pieces: a Next.js frontend with embedded auth, a Python backend that bundles the REST API, websocket server, agent executor, scheduler and notification workers in one container, a postgres database with the vector extension, a redis cluster for caching and events, and rabbitmq for the execution queue. This template wires all of it: database migrations run automatically on boot, secrets are generated per deploy, the API and websocket traffic share one public endpoint, and agent workspace files persist on a volume. You bring LLM provider keys (OpenAI, Anthropic, or others) and add them per user inside the app under Settings, then build and run agents.

## Common Use Cases

- Personal AI agent workbench: build agents that research, summarize, and post on schedules you control
- Automation backend for a team, with each member registering their own account and credentials
- A private alternative to hosted agent platforms when your prompts and data must stay on infrastructure you control

## Dependencies for AutoGPT Platform Hosting

### Deployment Dependencies

- An LLM provider API key (OpenAI, Anthropic, Groq, or any supported provider), added inside the app after signup
- Optional: OAuth client credentials for integrations you want agents to use (GitHub, Google, Notion, and others)

### Implementation Details

The backend image is built from the pinned upstream release autogpt-platform-beta-v0.7.0 and runs all backend processes in one container using upstream's own combined entrypoint. Database migrations apply automatically on every boot before the app starts. The REST API and the websocket server are served through a single public endpoint, with websocket traffic routed by path. Redis runs in single node cluster mode because the backend's cache client speaks cluster protocol only. Virus scanning of uploads is off by default to keep the footprint small; set CLAMAV_SERVICE_ENABLED to true and add a ClamAV service if you need it.

## Why Deploy AutoGPT Platform on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying AutoGPT Platform on Railway, you are one click away from a private agent building platform with zero yaml, zero manual migrations, and every credential generated for you. Sign up, add a provider key, and your first agent is running in minutes.
