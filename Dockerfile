# =============================================================================
# Dockerfile — multi-stage build for the MiniPlatform FastAPI app
#
# Stage 1 (builder): installs all dependencies into a virtual environment.
# Stage 2 (runtime): copies only the venv and source — no build tools, no cache.
#
# Result: a slim production image (~120 MB vs ~900 MB for a plain python:3.12).
# =============================================================================

# ── Stage 1: builder ────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build

# Install build tooling needed by some wheels (e.g. uvloop C extension)
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Create an isolated venv so Stage 2 can copy it cleanly
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy requirements first — Docker caches this layer until requirements change
COPY requirements.txt .
RUN pip install --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt


# ── Stage 2: runtime ────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Non-root user — never run app code as root in production
RUN groupadd --system appgroup \
 && useradd  --system --gid appgroup --no-create-home appuser

WORKDIR /app

# Copy only the pre-built venv from the builder stage
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy application source
COPY main.py .

# Ensure the non-root user owns the working directory
RUN chown -R appuser:appgroup /app

USER appuser

# Expose the port uvicorn listens on
EXPOSE 8000

# Health check so Docker (and Compose) know when the container is ready
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

# Start uvicorn with 2 workers; increase for production
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
