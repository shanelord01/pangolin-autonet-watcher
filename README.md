# pangolin-autonet-watcher
lightweight Docker container that automatically connects labeled containers to a specified Docker network.

I use this alongside the [docker.labelInjector](https://github.com/phyzical/docker.labelInjector) app on unraid to easily label Unraid apps.

Features
- Watches Docker events in real time
- Automatically connects containers to your chosen network
- Uses labels (no configuration files required)
- Supports custom network aliases
- Works on Unraid, Linux, Docker Desktop
- Extremely lightweight (Alpine-based, <10 MB)
- No polling, no cron — event-driven

## Environment Variables

The watcher is configured entirely through environment variables.  
You do not need to edit the script.

### Network / Label Mapping

Each pair of environment variables defines a mapping from a label key to a Docker network:

- `AUTONET_1_KEY` / `AUTONET_1_NET`
- `AUTONET_2_KEY` / `AUTONET_2_NET`
- `AUTONET_3_KEY` / `AUTONET_3_NET`
- etc.

For each index `N`:

- If a container has the label key defined in `AUTONET_N_KEY`
- Then it will be attached to the Docker network defined in `AUTONET_N_NET`

If the label is later removed and `AUTO_DISCONNECT=true`, the container is disconnected from that specific network, but retained on any other networks that still match.

Example:

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
Result:

Container is attached to networks pangolin and media_net.
If autonet.media is removed and AUTO_DISCONNECT=true, it is detached from media_net only.
Label values do not matter. Any non-empty value counts as "label exists".

# Alias Configuration

LABEL_ALIAS_KEY defines an optional label used to override the network alias for a container.
```env
LABEL_ALIAS_KEY=com.pangolin.autonet.alias
```
If a container has:
```env
com.pangolin.autonet.alias=immich-public
```
then immich-public will be used as the alias on all attached networks.
If no alias label is present, the container name is used.

Default:
```env
LABEL_ALIAS_KEY=com.pangolin.autonet.alias
```
# Initial Attach

INITIAL_ATTACH controls whether the watcher performs an initial scan and attaches containers on startup.

```env
INITIAL_ATTACH=true   # perform initial attach
INITIAL_ATTACH=false  # skip initial attach
```

Default: true.

INITIAL_RUNNING_ONLY controls whether the initial attach should consider only running containers.
```env
INITIAL_RUNNING_ONLY=true   # only running containers
INITIAL_RUNNING_ONLY=false  # all containers (running and stopped)
```
Default: false.

# Auto-Disconnect

AUTO_DISCONNECT controls whether the watcher should disconnect containers from networks when they lose the corresponding label.
```env
AUTO_DISCONNECT=true
AUTO_DISCONNECT=false
```
If AUTO_DISCONNECT=true:

When a label corresponding to AUTONET_N_KEY is removed from a container, it is disconnected from AUTONET_N_NET.
Other network attachments remain as long as their labels still exist.

Default: false.

# Logging

LOG_FILE is an optional path to a log file.
Logs are always written to stdout, and additionally to LOG_FILE if set.
```env
LOG_FILE=/var/log/pangolin-autonet-watcher.log
```
Default: no log file (stdout only).

# Example docker-compose.yml
Below is an example docker-compose.yml using three label/network mappings:
```
services:
  pangolin-autonet-watcher:
    image: shasam/pangolin-autonet-watcher:latest
    container_name: pangolin-autonet-watcher
    restart: always
    environment:
      # Label -> network mappings
      AUTONET_1_KEY: "autonet.pangolin"
      AUTONET_1_NET: "pangolin"

      AUTONET_2_KEY: "autonet.media"
      AUTONET_2_NET: "media_net"

      AUTONET_3_KEY: "autonet.tools"
      AUTONET_3_NET: "tools_net"

      # Optional alias label
      LABEL_ALIAS_KEY: "com.pangolin.autonet.alias"

      # Behaviour flags
      INITIAL_ATTACH: "true"
      INITIAL_RUNNING_ONLY: "false"
      AUTO_DISCONNECT: "true"

      # Optional logfile
      LOG_FILE: ""

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

# Example labels applied to containers
```
labels:
  autonet.pangolin: "true"
  autonet.media: "yes"
  com.pangolin.autonet.alias: "immich-public"
```
This container will then be attached to networks:

pangolin
media_net

with alias immich-public on both networks.

# To run:
```
git clone https://github.com/shanelord01/pangolin-autonet-watcher
cd pangolin-autonet-watcher
docker compose build
docker compose up -d
```


