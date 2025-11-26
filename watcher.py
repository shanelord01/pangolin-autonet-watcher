#!/usr/bin/env python3
import os
import sys
import time
import traceback
from datetime import datetime

import docker
from docker.errors import NotFound, APIError, DockerException


# ---------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------

def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def parse_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    value = value.strip().lower()
    if value in ("1", "true", "yes", "y", "on"):
        return True
    if value in ("0", "false", "no", "n", "off"):
        return False
    return default


# ---------------------------------------------------------
# Config loading
# ---------------------------------------------------------

def load_autonet_config():
    mappings = []
    index = 1

    while True:
        key_env = f"AUTONET_{index}_KEY"
        net_env = f"AUTONET_{index}_NET"

        key = os.getenv(key_env)
        net = os.getenv(net_env)

        if not key and not net:
            break

        if key and net:
            mappings.append(
                {
                    "index": index,
                    "label_key": key.strip(),
                    "network": net.strip(),
                }
            )
        else:
            log(f"Warning: AUTONET_{index}_KEY / AUTONET_{index}_NET not both set, ignoring index {index}")

        index += 1

    if not mappings:
        log("ERROR: No AUTONET_N_KEY / AUTONET_N_NET pairs found - exiting.")
        sys.exit(1)

    alias_label = os.getenv("LABEL_ALIAS_KEY", "com.pangolin.autonet.alias")

    initial_attach = parse_bool(os.getenv("INITIAL_ATTACH", "true"), True)
    initial_running_only = parse_bool(os.getenv("INITIAL_RUNNING_ONLY", "false"), False)
    auto_disconnect = parse_bool(os.getenv("AUTO_DISCONNECT", "true"), True)

    rescan_seconds_str = os.getenv("AUTONET_RESCAN_SECONDS", "30")
    try:
        rescan_seconds = max(0, int(rescan_seconds_str))
    except ValueError:
        rescan_seconds = 30

    debug = parse_bool(os.getenv("AUTONET_DEBUG", "false"), False)

    log("Loaded autonet configuration:")
    for m in mappings:
        log(f"  Index {m['index']}: label='{m['label_key']}' -> network='{m['network']}'")
    log(f"Alias label: {alias_label}")
    log(f"Initial attach: {initial_attach} (running only: {initial_running_only})")
    log(f"Auto-disconnect: {auto_disconnect}")
    log(f"Periodic rescan seconds: {rescan_seconds} (0 = disabled)")
    log(f"Debug: {debug}")

    return {
        "mappings": mappings,
        "alias_label": alias_label,
        "initial_attach": initial_attach,
        "initial_running_only": initial_running_only,
        "auto_disconnect": auto_disconnect,
        "rescan_seconds": resscan_seconds,
        "debug": debug,
    }


# ---------------------------------------------------------
# Core behaviour (Option C)
# ---------------------------------------------------------

def label_truthy(value) -> bool:
    if value is None:
        return False
    value = str(value).strip().lower()
    return value not in ("", "0", "false", "no", "off")


def detect_forbidden_network_mode(container, debug: bool = False):
    """
    Detects containers that cannot be attached/detached from networks:
    - network_mode=container:<name>
    - network_mode=host
    - network_mode=none
    Returns:
        (skip: bool, reason: str)
    """

    attrs = container.attrs
    host_config = attrs.get("HostConfig", {}) or {}

    mode = host_config.get("NetworkMode", "")

    if not isinstance(mode, str):
        return False, ""

    mode_lower = mode.strip().lower()

    # network_mode: container:<target>
    if mode_lower.startswith("container:"):
        return True, f"container:{mode_lower.split(':', 1)[1]}"

    # network_mode: host
    if mode_lower == "host":
        return True, "host"

    # network_mode: none
    if mode_lower == "none":
        return True, "none"

    return False, ""


def reconcile_container(client: docker.DockerClient, container, cfg, reason: str = "event") -> None:
    mappings = cfg["mappings"]
    alias_label = cfg["alias_label"]
    auto_disconnect = cfg["auto_disconnect"]
    debug = cfg["debug"]

    try:
        container.reload()
    except NotFound:
        if debug:
            log(f"[{reason}] Container disappeared before reconcile, skipping.")
        return
    except APIError as e:
        log(f"[{reason}] Error reloading container: {e}")
        return

    attrs = container.attrs
    name = attrs.get("Name", "").lstrip("/") or container.name
    labels = attrs.get("Config", {}).get("Labels", {}) or {}
    networks = attrs.get("NetworkSettings", {}).get("Networks", {}) or {}

    # -------------------------------------------------------------
    # SKIP IF container uses host/container/none network mode
    # -------------------------------------------------------------
    skip, mode_reason = detect_forbidden_network_mode(container, debug)
    if skip:
        log(f"Skipping '{name}': network_mode={mode_reason} — cannot attach/detach networks.")
        return

    if debug:
        log(f"[{reason}] Reconciling container '{name}' (id={container.short_id})")

    # -------------------------------------------------------------
    # Perform attach/detach reconciliation
    # -------------------------------------------------------------

    for m in mappings:
        label_key = m["label_key"]
        net_name = m["network"]

        wants_attach = label_truthy(labels.get(label_key))
        is_connected = net_name in networks

        alias = labels.get(alias_label, name)

        # ATTACH
        if wants_attach and not is_connected:
            try:
                if debug:
                    log(f"[{reason}] Connecting '{name}' to '{net_name}' with alias '{alias}' (index {m['index']})")
                client.api.connect_container_to_network(
                    container.id,
                    net_name,
                    aliases=[alias] if alias else None,
                )
                log(f"Connecting '{name}' to '{net_name}' with alias '{alias}' (index {m['index']})")
            except APIError as e:
                log(f"[{reason}] Failed to connect '{name}' to '{net_name}': {e}")

        # DETACH
        elif not wants_attach and is_connected and auto_disconnect:
            try:
                if debug:
                    log(f"[{reason}] Disconnecting '{name}' from '{net_name}' (index {m['index']})")
                client.api.disconnect_container_from_network(container.id, net_name)
                log(f"Disconnecting '{name}' from '{net_name}' (index {m['index']})")
            except APIError as e:
                log(f"[{reason}] Failed to disconnect '{name}' from '{net_name}': {e}")
        else:
            if debug:
                log(
                    f"[{reason}] No change for '{name}' on '{net_name}' "
                    f"(wants={wants_attach}, connected={is_connected})"
                )


def initial_attach_all(client: docker.DockerClient, cfg) -> None:
    if not cfg["initial_attach"]:
        log("Initial attach disabled by configuration.")
        return

    log("Running initial attach...")

    try:
        containers = client.containers.list(all=not cfg["initial_running_only"])
    except APIError as e:
        log(f"Error listing containers for initial attach: {e}")
        return

    for container in containers:
        reconcile_container(client, container, cfg, reason="initial")

    log("Initial attach complete.")


# ---------------------------------------------------------
# Event loop
# ---------------------------------------------------------

def event_loop(client: docker.DockerClient, cfg) -> None:
    relevant_statuses = {
        "start",
        "restart",
        "die",
        "stop",
        "destroy",
        "update",
        "rename",
    }

    debug = cfg["debug"]

    log("Event loop started")

    while True:
        try:
            for event in client.events(decode=True):
                if not isinstance(event, dict):
                    continue

                etype = event.get("Type")
                status = event.get("status") or event.get("Action")

                if etype != "container" or not status:
                    if debug:
                        log(f"[event] Ignoring non-container or missing-status event: {event}")
                    continue

                if status not in relevant_statuses:
                    if debug:
                        log(f"[event] Ignoring container event status='{status}'")
                    continue

                cid = event.get("id")
                if not cid:
                    if debug:
                        log(f"[event] Container event without id: {event}")
                    continue

                try:
                    container = client.containers.get(cid)
                except NotFound:
                    if debug:
                        log(f"[event] Container '{cid}' not found on status='{status}', skipping.")
                    continue
                except APIError as e:
                    log(f"[event] Error getting container '{cid}': {e}")
                    continue

                if debug:
                    name = container.name
                    log(f"[event] Processing status='{status}' for container '{name}' ({cid[:12]})")

                reconcile_container(client, container, cfg, reason=f"event:{status}")

        except Exception:
            log("Error in event loop, will retry shortly:")
            traceback.print_exc()
            time.sleep(5)
            log("Re-establishing Docker events stream...")


# ---------------------------------------------------------
# Periodic rescan
# ---------------------------------------------------------

def periodic_rescan_loop(client: docker.DockerClient, cfg) -> None:
    rescan_seconds = cfg["rescan_seconds"]
    debug = cfg["debug"]

    if rescan_seconds <= 0:
        log("Periodic rescan disabled (AUTONET_RESCAN_SECONDS <= 0).")
        return

    log(f"Periodic rescan thread started (interval {rescan_seconds} seconds).")

    while True:
        time.sleep(rescan_seconds)

        if debug:
            log("Periodic rescan: reconciling all containers.")

        try:
            containers = client.containers.list(all=True)
        except APIError as e:
            log(f"Error listing containers for periodic rescan: {e}")
            continue

        for container in containers:
            reconcile_container(client, container, cfg, reason="rescan")


# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

def main():
    try:
        client = docker.from_env()
    except Exception as e:
        log(f"Failed to create Docker client: {e}")
        sys.exit(1)

    cfg = load_autonet_config()

    initial_attach_all(client, cfg)

    import threading

    if cfg["rescan_seconds"] > 0:
        t = threading.Thread(target=periodic_rescan_loop, args=(client, cfg), daemon=True)
        t.start()

    event_loop(client, cfg)


if __name__ == "__main__":
    main()
