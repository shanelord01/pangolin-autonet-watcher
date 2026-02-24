#!/usr/bin/env bash
# set -euo pipefail retained for correctness on any future pre-exec logic.
# FIX L3: PYTHONUNBUFFERED removed — already set in Dockerfile ENV.
set -euo pipefail

echo "[ENTRYPOINT] Starting Pangolin Autonet Watcher (Python)..."

exec python3 /app/watcher.py
