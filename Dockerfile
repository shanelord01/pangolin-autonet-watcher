# Minimal Python image, good balance of size and compatibility
FROM python:3.12-slim

# FIX H1: Run as a non-root user.
# Default GID 999 matches the docker group on most standard Linux systems.
# Override at build time if your host uses a different GID:
#   docker build --build-arg DOCKER_GID=281 .
# Unraid users: your GID is typically 281. Check with:
#   stat -c '%g' /var/run/docker.sock
ARG DOCKER_GID=999

RUN groupadd -g ${DOCKER_GID} dockersock && \
    useradd -r -u 1000 -g dockersock -s /sbin/nologin appuser

WORKDIR /app

# Install only what we need
RUN pip install --no-cache-dir docker

# Copy code
COPY watcher.py /app/watcher.py
COPY entrypoint.sh /app/entrypoint.sh

# Ensure entrypoint is executable and transfer ownership
RUN chmod +x /app/entrypoint.sh && \
    chown -R appuser:dockersock /app

# Switch to non-root user
USER appuser

# Environment defaults (can all be overridden at runtime)
# PYTHONUNBUFFERED set here — entrypoint.sh does not need to re-export it.
ENV AUTONET_RESCAN_SECONDS=30 \
    INITIAL_ATTACH=true \
    INITIAL_RUNNING_ONLY=false \
    AUTO_DISCONNECT=true \
    LABEL_ALIAS_KEY=com.pangolin.autonet.alias \
    PYTHONUNBUFFERED=1

# FIX L4: Healthcheck — verifies the Docker socket is reachable.
# Catches a frozen event loop or lost socket without needing an external monitor.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python3 -c "import docker; docker.from_env().ping()" || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
