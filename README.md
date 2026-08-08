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

1. Deploy. First boot takes a few minutes: postgres initializes, backend applies migrations, frontend rewrites its baked URLs.
2. Open the frontend URL, create an account (first account is a normal user; registration is open, this is your private instance).
3. Settings, add your LLM provider key.
4. Build an agent in the builder, run it.

## Notes

- Virus scanning of uploads is disabled (`CLAMAV_SERVICE_ENABLED=false`). Add a ClamAV service and flip it if you need upload scanning.
- The knowledge graph memory feature (FalkorDB) is not deployed; upstream gates it behind a feature flag that self-host builds don't see.
- Upstream license for the platform is PolyForm Shield. Self-hosting for your own use is what this template does; do not resell it as a competing hosted service.

## Regenerating

Contract tests in `test/` run in CI before any image is pushed. To bump the upstream version: change `UPSTREAM_TAG` in `.github/workflows/build.yml` and the two image tags in `template.json`, push, wait for green, then redeploy services.
