# pangolin-autonet-watcher

A lightweight Docker container that automatically connects labeled containers to a specified Docker network.

I use this alongside the [docker.labelInjector](https://github.com/phyzical/docker.labelInjector) app on Unraid to easily label Unraid apps.

Once setup, you only need to add or remove labels from containers and this "app" will auto connect and auto disconnect them.

---

## Features

- Watches Docker events in real time
- Automatically connects containers to your chosen network
- Uses labels (no configuration files required)
- Supports custom network aliases
- Works on Unraid, Linux, Docker Desktop
- Runs as a non-root user
- Lightweight

---

## Configuration

The watcher is configured entirely through environment variables.  
You do **not** need to edit the script.

### Network / Label Mapping

Each pair of environment variables defines a mapping from a label key to a Docker network:

- `AUTONET_1_KEY` / `AUTONET_1_NET`
- `AUTONET_2_KEY` / `AUTONET_2_NET`
- `AUTONET_3_KEY` / `AUTONET_3_NET`
- etc.

For each index **N**:

- If a container has the label key defined in `AUTONET_N_KEY`,  
  then it will be attached to the Docker network defined in `AUTONET_N_NET`.

If the label is later removed and `AUTO_DISCONNECT=true`, the container is disconnected from that specific network, but retained on any other networks that still match.

#### Example Network/Label Mapping

```env
AUTONET_1_KEY=autonet.pangolin
AUTONET_1_NET=pangolin

AUTONET_2_KEY=autonet.media
AUTONET_2_NET=media_net
```

Container label examples:

```env
autonet.pangolin=true
autonet.media=yes
```

**Result:**  
Container is attached to networks `pangolin` and `media_net`.

If `autonet.media` is removed and `AUTO_DISCONNECT=true`, it is detached from `media_net` only.  
Label values do **not** matter. Any non-empty value counts as "label exists".

---

### Network Alias Configuration

`LABEL_ALIAS_KEY` defines an optional label used to override the network alias for a container.

```env
LABEL_ALIAS_KEY=com.pangolin.autonet.alias
```

If a container has:

```env
com.pangolin.autonet.alias=immich-public
```

then `immich-public` will be used as the alias on all attached networks.  
If no alias label is present, the container name is used.

Alias values must be valid DNS hostnames (letters, numbers, hyphens only — no spaces or special characters). Invalid values are automatically ignored and the container name is used as a fallback.

**Default:**
```env
LABEL_ALIAS_KEY=com.pangolin.autonet.alias
```

---

### Initial Attach

`INITIAL_ATTACH` controls whether the watcher performs an initial scan and attaches containers on startup.

```env
INITIAL_ATTACH=true   # perform initial attach
INITIAL_ATTACH=false  # skip initial attach
```
**Default:** `true`

`INITIAL_RUNNING_ONLY` controls whether the initial attach should consider only running containers.

```env
INITIAL_RUNNING_ONLY=true   # only running containers
INITIAL_RUNNING_ONLY=false  # all containers (running and stopped)
```
**Default:** `false`

---

### Auto-Disconnect

`AUTO_DISCONNECT` controls whether the watcher should disconnect containers from networks when they lose the corresponding label.

```env
AUTO_DISCONNECT=true
AUTO_DISCONNECT=false
```

If `AUTO_DISCONNECT=true`:

When a label corresponding to `AUTONET_N_KEY` is removed from a container, it is disconnected from `AUTONET_N_NET`.  
Other network attachments remain as long as their labels still exist.

**Default:** `false`

---

### Optional Environment Variables

#### AUTONET_RESCAN_SECONDS

Controls how often the watcher performs a full reconciliation of all containers and networks, independently of Docker events.

- **Type:** integer
- **Default:** 0 (disabled)
- **Recommended:** 30
- **Units:** seconds

If set to a non-zero value, the watcher periodically scans all containers and ensures their network attachments match the configured label rules.

```env
AUTONET_RESCAN_SECONDS="30"
```

#### AUTONET_DEBUG

Enables verbose logging, showing internal decision-making and extra details.

- **Type:** boolean
- **Default:** false
- **When to use:** Helpful during initial setup or troubleshooting only. Disable in normal operation.

```env
AUTONET_DEBUG="true"
```

#### LOG_FILE

Logs are always written to stdout, and additionally to `LOG_FILE` if set.

```env
LOG_FILE=/var/log/pangolin-autonet-watcher.log
```

**Default:** no log file (stdout only).

---

## Example `docker-compose.yml`

```yaml
services:
  pangolin-autonet-watcher:
    image: ghcr.io/shanelord01/pangolin-autonet-watcher:latest
    container_name: pangolin-autonet-watcher
    restart: unless-stopped

    # Add the host's docker group so the non-root user inside the container
    # can access /var/run/docker.sock (see Docker Socket Permissions below).
    group_add:
      - "999"

    # Container hardening
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true

    environment:
      AUTONET_1_KEY: "autonet.pangolin"
      AUTONET_1_NET: "pangolin"
      AUTONET_2_KEY: "autonet.media"
      AUTONET_2_NET: "media_net"
      LABEL_ALIAS_KEY: "com.pangolin.autonet.alias"
      INITIAL_ATTACH: "true"
      INITIAL_RUNNING_ONLY: "false"
      AUTO_DISCONNECT: "true"
      AUTONET_RESCAN_SECONDS: "30"
      AUTONET_DEBUG: "false"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

---

## Example Labels Applied to Containers

```yaml
labels:
  autonet.pangolin: "true"
  autonet.media: "yes"
  com.pangolin.autonet.alias: "immich-public"
```

This container will then be attached to networks:

- `pangolin`
- `media_net`

with alias `immich-public` on both networks.

---

## Docker Socket Permissions

This container runs as a non-root user (`appuser`, UID 1000). To allow it to access `/var/run/docker.sock`, you need to pass your host's docker group GID via `group_add` in your compose file.

Find your host's docker group GID:

```bash
stat -c '%g' /var/run/docker.sock
```

Then set that value in your `docker-compose.yml`:

```yaml
group_add:
  - "999"   # replace with your actual GID if different
```

Common GIDs by platform:

| Platform | Typical GID |
|----------|------------|
| Standard Linux (Ubuntu, Debian) | `999` |
| Unraid | `281` |
| Docker Desktop (Mac/Windows) | varies — check with the command above |

If you see `Permission denied` errors referencing the Docker socket in the container logs, this is the cause — check your GID and update `group_add` to match.

---

## Troubleshooting

### Permission denied on Docker socket

```
Error: Permission denied while trying to connect to the Docker daemon socket
```

Your `group_add` GID doesn't match the docker group on your host. Run `stat -c '%g' /var/run/docker.sock` and update `group_add` in your compose file to match, then recreate the container.

### Container marked unhealthy

The container includes a healthcheck that pings the Docker socket every 30 seconds. If it goes unhealthy, the most common causes are the socket permission issue above, or the Docker daemon restarting and dropping the event stream. The event loop reconnects automatically — if the healthcheck fails persistently, check `docker logs <container_name>` for errors.

### Container skipped with "network_mode=host"

Containers using `network_mode: host` or `network_mode: container:<x>` cannot have networks attached or detached dynamically. The watcher will log a message and skip those containers. This is expected behaviour.
