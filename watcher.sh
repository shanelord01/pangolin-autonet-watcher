#!/usr/bin/env bash
set -euo pipefail

##############################################################################
#                           ENV CONFIG / DEFAULTS                            #
##############################################################################

# Alias label key (optional)
LABEL_ALIAS_KEY="${LABEL_ALIAS_KEY:-com.pangolin.autonet.alias}"

# Initial attach on startup (true/false)
INITIAL_ATTACH="${INITIAL_ATTACH:-true}"

# Only attach running containers during initial attach (true/false)
INITIAL_RUNNING_ONLY="${INITIAL_RUNNING_ONLY:-false}"

# Auto-disconnect from networks when labels no longer exist (true/false)
AUTO_DISCONNECT="${AUTO_DISCONNECT:-false}"

# Optional log file path (stdout is always used)
LOG_FILE="${LOG_FILE:-}"

##############################################################################
#                                  LOGGING                                   #
##############################################################################

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  if [[ -n "$LOG_FILE" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

##############################################################################
#                      AUTONET CONFIG DISCOVERY (OPTION C)                   #
##############################################################################
# Pattern:
#   AUTONET_1_KEY=autonet.pangolin
#   AUTONET_1_NET=pangolin
#   AUTONET_2_KEY=autonet.media
#   AUTONET_2_NET=media_net
#   AUTONET_3_KEY=autonet.tools
#   AUTONET_3_NET=tools_net
##############################################################################

declare -a AUTONET_INDEXES=()
declare -A AUTONET_LABEL_KEYS=()
declare -A AUTONET_NETWORKS=()

load_autonet_config() {
  while IFS='=' read -r var_name var_value; do
    if [[ "$var_name" =~ ^AUTONET_([0-9]+)_KEY$ ]]; then
      local idx="${BASH_REMATCH[1]}"
      local key="$var_value"
      local net_var="AUTONET_${idx}_NET"
      local net="${!net_var:-}"

      if [[ -z "$key" || -z "$net" ]]; then
        log "Warning: AUTONET_${idx}_KEY or AUTONET_${idx}_NET missing; skipping index $idx"
        continue
      fi

      AUTONET_INDEXES+=("$idx")
      AUTONET_LABEL_KEYS["$idx"]="$key"
      AUTONET_NETWORKS["$idx"]="$net"
    fi
  done < <(env)

  if [[ ${#AUTONET_INDEXES[@]} -eq 0 ]]; then
    log "ERROR: No AUTONET_N_KEY / AUTONET_N_NET pairs found. Exiting."
    exit 1
  fi

  log "Loaded autonet configuration:"
  for idx in "${AUTONET_INDEXES[@]}"; do
    log "  Index $idx: label='${AUTONET_LABEL_KEYS[$idx]}' -> network='${AUTONET_NETWORKS[$idx]}'"
  done
}

##############################################################################
#                                DOCKER HELPERS                              #
##############################################################################

ensure_networks() {
  for idx in "${AUTONET_INDEXES[@]}"; do
    local net="${AUTONET_NETWORKS[$idx]}"
    if ! docker network inspect "$net" >/dev/null 2>&1; then
      log "Creating network: $net"
      docker network create "$net"
    fi
  done
}

container_has_label_for_index() {
  local cname="$1"
  local idx="$2"

  local key="${AUTONET_LABEL_KEYS[$idx]}"
  local val
  val=$(docker inspect -f "{{ index .Config.Labels \"$key\" }}" "$cname" 2>/dev/null || echo "")

  if [[ -z "$val" || "$val" == "<no value>" ]]; then
    return 1
  fi

  return 0
}

get_alias() {
  local cname="$1"
  local alias
  alias=$(docker inspect -f "{{ index .Config.Labels \"$LABEL_ALIAS_KEY\" }}" "$cname" 2>/dev/null || echo "")

  if [[ -z "$alias" || "$alias" == "<no value>" ]]; then
    alias="$cname"
  fi

  echo "$alias"
}

connect_network_for_index() {
  local cname="$1"
  local alias="$2"
  local idx="$3"
  local net="${AUTONET_NETWORKS[$idx]}"

  if docker inspect -f '{{json .NetworkSettings.Networks}}' "$cname" 2>/dev/null | grep -q "\"$net\""; then
    return
  fi

  log "Connecting '$cname' to '$net' with alias '$alias' (index $idx)"
  docker network connect --alias "$alias" "$net" "$cname" || log "Warning: failed to connect"
}

disconnect_network_for_index() {
  local cname="$1"
  local idx="$2"
  local net="${AUTONET_NETWORKS[$idx]}"

  if docker inspect -f '{{json .NetworkSettings.Networks}}' "$cname" 2>/dev/null | grep -q "\"$net\""; then
    log "Disconnecting '$cname' from '$net' (index $idx)"
    docker network disconnect "$net" "$cname" || log "Warning: failed to disconnect"
  fi
}

attach_for_all_matching_labels() {
  local cname="$1"
  local alias
  alias=$(get_alias "$cname")

  for idx in "${AUTONET_INDEXES[@]}"; do
    if container_has_label_for_index "$cname" "$idx"; then
      connect_network_for_index "$cname" "$alias" "$idx"
    fi
  done
}

detach_for_all_missing_labels() {
  local cname="$1"

  for idx in "${AUTONET_INDEXES[@]}"; do
    if ! container_has_label_for_index "$cname" "$idx"; then
      disconnect_network_for_index "$cname" "$idx"
    fi
  done
}

##############################################################################
#                             INITIAL ATTACH                                 #
##############################################################################

initial_attach() {
  if [[ "$INITIAL_ATTACH" != "true" ]]; then
    log "Initial attach skipped (INITIAL_ATTACH=false)"
    return
  fi

  log "Running initial attach..."

  local cids
  if [[ "$INITIAL_RUNNING_ONLY" == "true" ]]; then
    cids=$(docker ps -q)
  else
    cids=$(docker ps -aq)
  fi

  for cid in $cids; do
    local cname
    cname=$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##' 2>/dev/null || true)
    [[ -z "$cname" ]] && continue

    attach_for_all_matching_labels "$cname"
  done

  log "Initial attach complete."
}

##############################################################################
#                               EVENT LOOP                                   #
##############################################################################

event_loop() {
  log "Event loop started"
  log "Alias label: $LABEL_ALIAS_KEY"
  log "Initial attach: $INITIAL_ATTACH (running only: $INITIAL_RUNNING_ONLY)"
  log "Auto-disconnect: $AUTO_DISCONNECT"
  log ""

  docker events --format '{{json .}}' |
  while read -r event_json; do
    [[ -z "$event_json" ]] && continue

    local event cname
    event=$(echo "$event_json" | jq -r '.status')
    cname=$(echo "$event_json" | jq -r '.Actor.Attributes.name')

    [[ -z "$event" || -z "$cname" ]] && continue

    case "$event" in
      start|update)
        attach_for_all_matching_labels "$cname"
        if [[ "$AUTO_DISCONNECT" == "true" ]]; then
          detach_for_all_missing_labels "$cname"
        fi
        ;;
    esac
  done
}

##############################################################################
#                                    MAIN                                    #
##############################################################################

load_autonet_config
ensure_networks
initial_attach
event_loop
