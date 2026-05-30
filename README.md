# MiniPlatform — Week 2: Containerized Microservices App

Three-service Docker Compose stack: **FastAPI + Redis + Nginx**.  
Part of the Phase 1 DevOps foundations project series.

---

## Architecture

```
Browser / curl
      │
      ▼
  Nginx :80              ← single entry point
  ├── GET /              → static landing page
  └── GET /api/*         → proxied to app:8000
                                  │
                            FastAPI app            ← /health, /api/data, /metrics
                                  │
                               Redis               ← caches /api/data for REDIS_TTL secs
```

Networks:
- `frontend` — Nginx ↔ app (bridge, externally reachable)
- `backend`  — app ↔ Redis (bridge, `internal: true` — no internet access)

---

## Quickstart

```bash
# 1. Clone and enter the project
git clone https://github.com/youruser/miniplatform
cd miniplatform

# 2. Copy and configure environment variables
cp .env.example .env
# Edit .env — set IMAGE_REPO to your Docker Hub / GHCR username

# 3. Start the stack (builds app image locally on first run)
docker compose up -d

# 4. Verify everything is healthy
docker compose ps
curl http://localhost/api/health
curl http://localhost/api/data       # first call: cache miss
curl http://localhost/api/data       # second call: cache hit
```

Open [http://localhost](http://localhost) in your browser for the landing page.

---

## Development workflow (hot reload)

The `docker-compose.override.yml` is automatically merged in local dev:

```bash
docker compose up        # hot reload enabled; edit app/main.py and save
```

Direct access (no Nginx hop):
- API docs: [http://localhost:8000/docs](http://localhost:8000/docs)
- Redis CLI: `redis-cli -h localhost`

---

## Building and pushing the image

```bash
# Build for current platform
docker build -t ghcr.io/youruser/miniplatform-app:latest ./app

# Build and push multi-platform (amd64 + arm64)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ghcr.io/youruser/miniplatform-app:latest \
  --push \
  ./app

# Analyse image size (install: https://github.com/wagoodman/dive)
dive ghcr.io/youruser/miniplatform-app:latest
```

---

## Endpoints

| Method | Path          | Description                              |
|--------|---------------|------------------------------------------|
| GET    | `/`           | Static landing page (served by Nginx)    |
| GET    | `/api/data`   | JSON payload; Redis-cached for REDIS_TTL |
| GET    | `/api/health` | Readiness probe — checks Redis           |
| GET    | `/health`     | Liveness probe — process alive check     |
| GET    | `/metrics`    | Prometheus metrics (used in Week 4)      |

---

## Environment variables

| Variable        | Default                          | Description                        |
|-----------------|----------------------------------|------------------------------------|
| `NGINX_PORT`    | `80`                             | Host port for Nginx                |
| `REDIS_TTL`     | `30`                             | Cache TTL in seconds               |
| `REDIS_MAXMEM`  | `128mb`                          | Redis max memory (LRU eviction)    |
| `APP_ENV`       | `production`                     | Label in /api/data response        |
| `IMAGE_REGISTRY`| `ghcr.io`                        | Container registry                 |
| `IMAGE_REPO`    | `youruser/miniplatform-app`      | Image repository path              |
| `IMAGE_TAG`     | `latest`                         | Image tag                          |

---

## Useful commands

```bash
# Stream logs from all services
docker compose logs -f

# Stream logs from one service
docker compose logs -f app

# Inspect Redis cache
docker compose exec redis redis-cli keys '*'
docker compose exec redis redis-cli get api:data

# Open a shell in the app container
docker compose exec app /bin/bash

# Stop and remove containers (keeps named volumes)
docker compose down

# Stop and remove containers AND volumes
docker compose down -v
```

---

## Stretch goals

- [ ] Run `dive` and reduce the image size by 30%+
- [ ] Add `.env` substitution for all hardcoded values (already done ✓)
- [ ] Write `docker-compose.override.yml` for dev hot reload (already done ✓)
- [ ] Add a `/chaos` endpoint that spikes CPU (connects to the MiniPlatform capstone)
- [ ] Push a multi-arch image with `docker buildx` for arm64 + amd64

---

## Project structure

```
microservices-app/
├── app/
│   ├── main.py                  # FastAPI application
│   ├── requirements.txt
│   └── Dockerfile               # multi-stage build
├── nginx/
│   ├── nginx.conf               # reverse proxy config
│   └── static/index.html        # landing page
├── docker-compose.yml           # production stack
├── docker-compose.override.yml  # local dev overrides (auto-merged)
├── .env.example                 # committed — template for .env
├── .dockerignore
└── README.md
```
