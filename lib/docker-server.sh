#!/usr/bin/env bash
# Docker dedicated-server wrappers. Requires config vars DOCKER_COMPOSE_DIR,
# DOCKER_SERVICE_NAME, DOCKER_CONTAINER_NAME, VTT_MOD_DISPLAY_NAME (the name that
# appears in "Loaded Mod: <name>" in the server log, used as the readiness marker).
# Source this after lib/common.sh, don't execute it.

docker_server_start() {
    require_var DOCKER_COMPOSE_DIR
    require_var DOCKER_SERVICE_NAME
    log "starting Docker server ($DOCKER_SERVICE_NAME in $DOCKER_COMPOSE_DIR)..."
    (cd "$DOCKER_COMPOSE_DIR" && docker compose up -d "$DOCKER_SERVICE_NAME")
}

docker_server_stop() {
    require_var DOCKER_COMPOSE_DIR
    require_var DOCKER_SERVICE_NAME
    log "stopping Docker server ($DOCKER_SERVICE_NAME)..."
    (cd "$DOCKER_COMPOSE_DIR" && docker compose stop "$DOCKER_SERVICE_NAME")
}

docker_server_restart() {
    require_var DOCKER_COMPOSE_DIR
    require_var DOCKER_SERVICE_NAME
    # A restarted server writes a brand-new output_log__*.txt, but it takes a beat to
    # appear. Capture the pre-restart log path and wait for it to change before
    # returning, or docker_server_wait_mod_loaded/wait_started called right after this
    # would read the OLD (already-complete) log and report success instantly - this bit
    # a real run, where the client tried to connect before the new world had actually
    # finished starting and got rejected ("still initializing the server").
    local previous_log
    previous_log="$(docker_server_latest_log)"
    log "restarting Docker server ($DOCKER_SERVICE_NAME)..."
    (cd "$DOCKER_COMPOSE_DIR" && docker compose restart "$DOCKER_SERVICE_NAME")
    docker_server_wait_new_log "$previous_log" 60
}

# docker_server_latest_log: prints the path of the most recently created server log.
docker_server_latest_log() {
    require_var DOCKER_COMPOSE_DIR
    # shellcheck disable=SC2012 # filenames here are timestamp-based, non-alphanumeric edge cases don't apply
    ls -t "${DOCKER_COMPOSE_DIR}/data/serverfiles"/output_log__*.txt 2>/dev/null | head -1
}

# docker_server_wait_new_log <previous_log_path> [timeout_seconds]: blocks until
# docker_server_latest_log returns something other than previous_log_path.
docker_server_wait_new_log() {
    local previous_log="$1"
    local timeout="${2:-60}"
    local waited=0
    log "waiting for a new server log file to appear (previous: ${previous_log:-<none>})..."
    while true; do
        local current_log
        current_log="$(docker_server_latest_log)"
        if [ -n "$current_log" ] && [ "$current_log" != "$previous_log" ]; then
            log "new log file: $current_log"
            return 0
        fi
        if [ "$waited" -ge "$timeout" ]; then
            die "timed out waiting for a new server log file to appear (still $previous_log)"
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

# docker_server_wait_mod_loaded [timeout_seconds]: blocks until the server log shows
# the VisitedTraderTeleport mod loaded, or dies after the timeout.
docker_server_wait_mod_loaded() {
    require_var VTT_MOD_DISPLAY_NAME
    local timeout="${1:-60}"
    local waited=0
    log "waiting for '$VTT_MOD_DISPLAY_NAME' to load in the server log (timeout ${timeout}s)..."
    while true; do
        local logfile
        logfile="$(docker_server_latest_log)"
        if [ -n "$logfile" ] && grep -q "Loaded Mod: ${VTT_MOD_DISPLAY_NAME}" "$logfile" 2>/dev/null; then
            log "mod loaded (per $logfile)"
            return 0
        fi
        if [ "$waited" -ge "$timeout" ]; then
            die "timed out waiting for '$VTT_MOD_DISPLAY_NAME' to appear in the server log"
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

# docker_server_wait_started [timeout_seconds]: blocks until the world has fully
# started ("StartGame done" in the log), not just the mod list load.
docker_server_wait_started() {
    local timeout="${1:-180}"
    local waited=0
    log "waiting for the world to finish starting (timeout ${timeout}s)..."
    while true; do
        local logfile
        logfile="$(docker_server_latest_log)"
        if [ -n "$logfile" ] && grep -q "StartGame done" "$logfile" 2>/dev/null; then
            log "world started (per $logfile)"
            return 0
        fi
        if [ "$waited" -ge "$timeout" ]; then
            die "timed out waiting for the world to finish starting"
        fi
        sleep 3
        waited=$((waited + 3))
    done
}
