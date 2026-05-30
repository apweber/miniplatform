# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack

Three-service Docker Compose stack: **Nginx → FastAPI (app) → Redis**.

- `nginx/` — reverse proxy; serves static landing page at `/`, proxies `/api/*` to FastAPI
- `app/` — FastAPI backend (`main.py`); Redis-cached `/api/data`, Prometheus metrics at `/metrics`
- `health_check/` — standalone Bash health monitor with Bats tests (not containerized)

## Common commands

```bash
# Start (dev, with hot reload and exposed ports 8000/6379)
docker compose up

# Start detached (production-like)
docker compose up -d

# Rebuild app image after dependency changes
docker compose build app

# Stream logs
docker compose logs -f [app|nginx|redis]

# Verify endpoints
curl http://localhost/api/health
curl http://localhost/api/data      # first: cache miss; second: cache hit

# Inspect Redis cache
docker compose exec redis redis-cli keys '*'
docker compose exec redis redis-cli get api:data

# Direct API access (dev only, bypasses Nginx)
# http://localhost:8000/docs

# Run health_check.sh tests
bats health_check/health_check.bats

# Run health check once
./health_check/health_check.sh --report
```

## Architecture notes

**Network isolation**: Two Docker networks. `frontend` (bridge) connects Nginx ↔ app. `backend` (bridge, `internal: true`) connects app ↔ Redis. Redis has no internet access and is never on the frontend network.

**Startup order**: Compose `depends_on` with `condition: service_healthy` enforces Redis → app → Nginx ordering. All three services have healthchecks defined.

**Dev vs prod**: `docker-compose.override.yml` is auto-merged locally. It bind-mounts `./app` into the container, enables uvicorn `--reload`, exposes ports 8000 and 6379, and targets the `builder` Docker stage (which includes gcc). Production uses the `runtime` stage — a slim image with only the venv copied in, running as a non-root user.

**Caching pattern**: `GET /api/data` checks Redis key `api:data` first. On miss it builds the payload and calls `cache.setex(cache_key, REDIS_TTL, ...)`. Redis errors are caught and logged but don't 503 — the app degrades gracefully.

**Prometheus metrics**: `main.py` registers `http_requests_total`, `http_request_duration_seconds`, `cache_hits_total`, `cache_misses_total`, and `redis_up` via a middleware. The `/metrics` endpoint is intended for Prometheus scraping in a later observability phase.

## Environment variables

Copy `.env.example` to `.env` before first run. Key vars:

| Variable | Default | Notes |
|---|---|---|
| `NGINX_PORT` | `80` | Host port for Nginx |
| `REDIS_TTL` | `30` | Cache TTL in seconds |
| `APP_ENV` | `production` | Label in `/api/data` response |
| `IMAGE_REPO` | `youruser/miniplatform-app` | Set to your registry path |

## Health check script

`health_check/health_check.sh` is a standalone Bash monitor (not wired into Docker). It checks CPU, memory, disk, and systemd service status against configurable warn/crit thresholds, logs structured entries, and optionally POSTs to a Slack webhook. Thresholds can be overridden via `health_check/health_check.conf` or environment variables. Alert deduplication uses file-based cooldown stamps in `COOLDOWN_DIR`.

Tests use [bats-core](https://github.com/bats-core/bats-core) and override `LOG_FILE`, `COOLDOWN_DIR`, and thresholds via env vars to avoid touching `/var/log` or hitting Slack.
