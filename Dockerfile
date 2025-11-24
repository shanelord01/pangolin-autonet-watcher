# Minimal Python image, good balance of size and compatibility
FROM python:3.12-slim

# We need root to read /var/run/docker.sock on host (socket perms are 660 root:docker)
# and inside the container we typically don't have docker group mapped, so stay root.
WORKDIR /app

# Install only what we need
RUN pip install --no-cache-dir docker

# Copy code
COPY watcher.py /app/watcher.py
COPY entrypoint.sh /app/entrypoint.sh

# Ensure entrypoint is executable
RUN chmod +x /app/entrypoint.sh

# Environment defaults (can all be overridden)
ENV AUTONET_RESCAN_SECONDS=30 \
    INITIAL_ATTACH=true \
    INITIAL_RUNNING_ONLY=false \
    AUTO_DISCONNECT=true \
    LABEL_ALIAS_KEY=com.pangolin.autonet.alias \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["/app/entrypoint.sh"]
