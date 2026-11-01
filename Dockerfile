FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

# curl is needed for the HEALTHCHECK below; python:slim doesn't include it.
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

RUN useradd -m appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN chmod +x scripts/docker-entrypoint.sh

# Create runtime directories and hand ownership of the entire /app tree to appuser
RUN mkdir -p /app/staticfiles /app/media /app/data \
    && chown -R appuser:appuser /app

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD curl -f http://localhost:8000/health/ || exit 1

ENTRYPOINT ["scripts/docker-entrypoint.sh"]
CMD ["gunicorn", "musicplayer.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3"]