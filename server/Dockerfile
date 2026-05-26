# ── Stage 1: install deps ────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /app

COPY server/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: lean runtime image ──────────────────────────────────────────────
FROM python:3.11-slim

RUN apt-get purge -y --auto-remove && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /install /usr/local
COPY server/main.py .

# Python memory / GC tuning
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONMALLOC=malloc \
    MALLOC_TRIM_THRESHOLD_=65536

# Railway sets PORT automatically
EXPOSE 8000

# ── Uvicorn flags ─────────────────────────────────────────────────────────────
#
# --timeout-keep-alive 300
#   Keep the TCP connection alive for 5 minutes between chunk uploads.
#   Prevents Railway's load balancer from closing the socket mid-transfer.
#
# --limit-concurrency 20
#   Hard cap on simultaneous in-flight requests to bound memory.
#
# --h11-max-incomplete-event-size 33554432
#   Allow h11 to buffer up to 32 MB of HTTP headers + first line.
#   Required for large multipart request parsing.
#
# Single worker — predictable RAM ceiling on Railway free plan (512 MB).
#
CMD ["sh", "-c", "uvicorn main:app \
  --host 0.0.0.0 \
  --port ${PORT:-8000} \
  --workers 1 \
  --loop asyncio \
  --http h11 \
  --log-level warning \
  --no-access-log \
  --timeout-keep-alive 300 \
  --limit-concurrency 20 \
  --h11-max-incomplete-event-size 33554432"]
