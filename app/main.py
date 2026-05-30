"""
main.py — FastAPI backend for the MiniPlatform microservices app (Week 2)

Endpoints:
  GET /health       — liveness probe (no Redis dependency)
  GET /api/health   — readiness probe (checks Redis connection)
  GET /api/data     — returns a payload; cached in Redis for REDIS_TTL seconds
  GET /metrics      — Prometheus metrics (used in Week 4 observability project)
"""

import os
import json
import time
import socket
import logging

import redis
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("miniplatform")

# ---------------------------------------------------------------------------
# Config from environment (set in .env / docker-compose.yml)
# ---------------------------------------------------------------------------
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_TTL  = int(os.getenv("REDIS_TTL", "30"))   # seconds to cache /api/data
APP_ENV    = os.getenv("APP_ENV", "development")

# ---------------------------------------------------------------------------
# Redis client (decode_responses=True → strings, not bytes)
# ---------------------------------------------------------------------------
cache = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    decode_responses=True,
    socket_connect_timeout=2,
    socket_timeout=2,
)

# ---------------------------------------------------------------------------
# Prometheus metrics (carried forward into Week 4)
# ---------------------------------------------------------------------------
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5],
)
CACHE_HITS   = Counter("cache_hits_total",   "Redis cache hits")
CACHE_MISSES = Counter("cache_misses_total", "Redis cache misses")
REDIS_UP     = Gauge("redis_up", "1 if Redis is reachable, 0 otherwise")

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(title="MiniPlatform API", version="1.0.0")


# ---------------------------------------------------------------------------
# Middleware: record latency + request count for every route
# ---------------------------------------------------------------------------
@app.middleware("http")
async def metrics_middleware(request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    duration = time.perf_counter() - start
    endpoint = request.url.path
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=endpoint,
        status=response.status_code,
    ).inc()
    REQUEST_LATENCY.labels(endpoint=endpoint).observe(duration)
    return response


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health", tags=["ops"])
def liveness():
    """Liveness probe — always returns 200 if the process is alive."""
    return {"status": "ok", "host": socket.gethostname()}


@app.get("/api/health", tags=["ops"])
def readiness():
    """Readiness probe — confirms Redis is reachable before accepting traffic."""
    try:
        cache.ping()
        REDIS_UP.set(1)
        return {"status": "ok", "redis": "reachable"}
    except redis.RedisError as exc:
        REDIS_UP.set(0)
        logger.warning("Redis ping failed: %s", exc)
        raise HTTPException(status_code=503, detail="Redis unavailable") from exc


@app.get("/api/data", tags=["data"])
def get_data():
    """
    Returns a small JSON payload.
    The result is cached in Redis for REDIS_TTL seconds.
    Cache hit/miss counts are tracked as Prometheus metrics.
    """
    cache_key = "api:data"

    # --- Cache hit ---
    cached = None
    try:
        cached = cache.get(cache_key)
    except redis.RedisError as exc:
        logger.warning("Redis GET failed (will compute fresh): %s", exc)

    if cached:
        CACHE_HITS.inc()
        logger.info("Cache HIT for key '%s'", cache_key)
        payload = json.loads(cached)
        payload["cache"] = "hit"
        return JSONResponse(content=payload)

    # --- Cache miss: build payload ---
    CACHE_MISSES.inc()
    logger.info("Cache MISS for key '%s'", cache_key)

    payload = {
        "message": "Hello from MiniPlatform",
        "host": socket.gethostname(),
        "env": APP_ENV,
        "timestamp": time.time(),
        "cache": "miss",
    }

    try:
        cache.setex(cache_key, REDIS_TTL, json.dumps(payload))
    except redis.RedisError as exc:
        logger.warning("Redis SET failed (returning uncached response): %s", exc)

    return JSONResponse(content=payload)


@app.get("/metrics", tags=["ops"])
def metrics():
    """Prometheus metrics endpoint — scraped by Prometheus in Week 4."""
    return PlainTextResponse(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST,
    )
