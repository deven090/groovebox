#!/usr/bin/env bash
set -euo pipefail

ECR_REPO="${ECR_REPOSITORY:-}"

if [[ -n "${ECR_REPO}" ]]; then
    echo "[deploy] Pulling latest image from ${ECR_REPO}..."
    docker pull "${ECR_REPO}:latest"
fi

echo "[deploy] Starting containers..."
docker compose up -d

echo "[deploy] Waiting for app to come up..."
sleep 5

echo "[deploy] Running healthcheck..."
if ./scripts/healthcheck.sh; then
    echo "[deploy] Deploy succeeded."
else
    echo "[deploy] Healthcheck failed after deploy!"
    exit 1
fi
