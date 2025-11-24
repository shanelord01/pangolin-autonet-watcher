#!/usr/bin/env bash
set -euo pipefail

# Simple wrapper so logs are clean and any unexpected crash is visible.

echo "[ENTRYPOINT] Starting Pangolin Autonet Watcher (Python)..."

# Keep stdout unbuffered
export PYTHONUNBUFFERED=1

exec python3 /app/watcher.py
