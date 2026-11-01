#!/usr/bin/env bash
set -euo pipefail

HOST="${HEALTHCHECK_HOST:-localhost}"
PORT="${HEALTHCHECK_PORT:-80}"
URL="http://${HOST}:${PORT}/health/"

echo "[healthcheck] Checking ${URL}..."

if curl -fsS "${URL}" > /dev/null; then
    echo "[healthcheck] OK"
    exit 0
else
    echo "[healthcheck] FAILED"
    exit 1
fi
