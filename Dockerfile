# Backend Dockerfile - Multi-stage build with Gunicorn+Uvicorn
# Builder stage
FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    POETRY_VIRTUALENVS_CREATE=false

# System deps for building common Python packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies to a temporary location to copy into runtime
COPY requirements.txt ./
RUN pip install --upgrade pip && \
    pip install --prefix=/install -r requirements.txt

# Runtime stage
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# Create non-root user
RUN addgroup --system app && adduser --system --ingroup app app

# Copy installed site-packages from builder
COPY --from=builder /install /usr/local

WORKDIR /app

# Copy application code
COPY . /app

# Expose port
EXPOSE 8080

USER app

# Default command: Gunicorn with Uvicorn workers
# Note: Ensure main:app exists
CMD ["gunicorn", "-k", "uvicorn.workers.UvicornWorker", "-w", "2", "-b", "0.0.0.0:8080", "main:app"]
