#!/usr/bin/env bash
set -euo pipefail

echo "[setup] Installing dependencies..."
pip install -r requirements.txt

echo "[setup] Running migrations..."
python manage.py migrate

echo "[setup] Collecting static files..."
python manage.py collectstatic --noinput

echo "[setup] Done."
