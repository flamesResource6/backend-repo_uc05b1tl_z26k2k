# Backend Dockerfile - FastAPI (Python 3.11) - Multi-stage

# ----- Builder stage -----
FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# System deps for building some wheels (if needed)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy only requirements first for better caching
COPY requirements.txt ./
RUN pip install --upgrade pip && \
    pip wheel --no-cache-dir --no-deps -r requirements.txt -w /wheels

# ----- Runtime stage -----
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

# Create non-root user
RUN addgroup --system app && adduser --system --ingroup app app

# Runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy wheels and install
COPY --from=builder /wheels /wheels
COPY requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir /wheels/*

# Copy application code
COPY . /app

# Expose port
EXPOSE 8000

USER app

# Use Gunicorn with Uvicorn workers for production
CMD ["gunicorn", "-k", "uvicorn.workers.UvicornWorker", "-w", "2", "-b", "0.0.0.0:8000", "main:app"]
