#!/usr/bin/env bash
set -euo pipefail

echo "[test] Running Django test suite..."
python manage.py test

echo "[test] All tests passed."
