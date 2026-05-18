# ── Stage 1: install deps in a builder layer ─────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /app

# Only copy requirements first (layer cache-friendly)
COPY requirements.txt .

# Install into a prefix so we can copy cleanly
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: lean runtime image ───────────────────────────────────────────────
FROM python:3.11-slim

# Drop unnecessary packages + clear apt cache to shrink image
RUN apt-get purge -y --auto-remove && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy only the installed packages from builder
COPY --from=builder /install /usr/local

# Copy source
COPY main.py .

# Set Python memory/GC env vars
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONMALLOC=malloc \
    MALLOC_TRIM_THRESHOLD_=65536

# Railway sets PORT automatically
EXPOSE 8000

# Single worker, no reload — predictable memory ceiling
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --workers 1 --loop asyncio --http h11 --log-level warning --no-access-log"]
