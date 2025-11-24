#!/bin/sh
set -e

# Wait for Docker engine
until docker info >/dev/null 2>&1; do
  echo "Waiting for Docker engine..."
  sleep 1
done

exec /watcher.sh
