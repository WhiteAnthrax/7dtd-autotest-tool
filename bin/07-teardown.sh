#!/usr/bin/env bash
# Restores both mods from backup, stops the client process/scheduled task, and stops the
# Docker server. Deliberately does NOT use `set -e`: this runs from run-roundtrip.sh's
# EXIT trap even after an earlier step failed, so every step here should be attempted
# regardless of whether an earlier one in this same script failed.
# Usage: 07-teardown.sh <profile>
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"
# shellcheck source=lib/docker-server.sh
source "$ROOT_DIR/lib/docker-server.sh"

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"

# --- Client: stop process/task ---
if [ -n "${CLIENT_EXE_NAME:-}" ] && [ -n "${OMEN_TASK_NAME:-}" ]; then
    log "stopping client process/task..."
    PROC_NAME="${CLIENT_EXE_NAME%.exe}"
    run_on_omen_script "$ROOT_DIR/lib/windows/Stop-TestPilotClient.ps1" \
        -ProcessName "\"${PROC_NAME}\"" -TaskName "\"${OMEN_TASK_NAME}\"" \
        || log "warn: failed to stop client process/task (continuing)"
else
    log "warn: CLIENT_EXE_NAME/OMEN_TASK_NAME not set, skipping client stop"
fi

# --- Client: restore mods ---
if [ -n "${CLIENT_MODS_DIR:-}" ] && [ -n "${VTT_CLIENT_MOD_DIRNAME:-}" ] && [ -n "${OMEN_SCRATCH_DIR:-}" ]; then
    CLIENT_VTT_DIR="${CLIENT_MODS_DIR}\\${VTT_CLIENT_MOD_DIRNAME}"
    CLIENT_BACKUP_DIR="${OMEN_SCRATCH_DIR}\\mod-backup"
    log "restoring client-side VisitedTraderTeleport from backup..."
    run_on_omen_cmd "Copy-Item '${CLIENT_BACKUP_DIR}\\VisitedTraderTeleport.dll.orig' '${CLIENT_VTT_DIR}\\VisitedTraderTeleport.dll' -Force -ErrorAction SilentlyContinue; Remove-Item '${CLIENT_VTT_DIR}\\EnableTestHarness.txt' -Force -ErrorAction SilentlyContinue" \
        || log "warn: failed to restore client-side VisitedTraderTeleport (continuing)"

    log "removing SdtdTestPilot from the client..."
    run_on_omen_cmd "Remove-Item '${CLIENT_MODS_DIR}\\SdtdTestPilot' -Recurse -Force -ErrorAction SilentlyContinue" \
        || log "warn: failed to remove client-side SdtdTestPilot (continuing)"
else
    log "warn: client mod dir config not set, skipping client mod restore"
fi

# --- Client: remove scratch dir (queue + build workspace) ---
if [ -n "${OMEN_QUEUE_DIR:-}" ]; then
    run_on_omen_cmd "Remove-Item '${OMEN_QUEUE_DIR}' -Recurse -Force -ErrorAction SilentlyContinue" \
        || log "warn: failed to remove queue dir (continuing)"
fi

# --- Server: restore mod ---
if [ -n "${SERVER_MODS_DIR:-}" ]; then
    SERVER_VTT_DIR="$SERVER_MODS_DIR/VisitedTraderTeleport"
    SERVER_BACKUP_DIR="$OUTPUT_DIR/server-mod-backup"
    if [ -d "$SERVER_BACKUP_DIR" ]; then
        log "restoring server-side VisitedTraderTeleport from backup..."
        cp -f "$SERVER_BACKUP_DIR/VisitedTraderTeleport.dll" "$SERVER_VTT_DIR/VisitedTraderTeleport.dll" \
            || log "warn: failed to restore server-side VisitedTraderTeleport.dll (continuing)"
        rm -f "$SERVER_VTT_DIR/EnableTestHarness.txt"
    else
        log "warn: no server-side backup found at $SERVER_BACKUP_DIR, leaving server mod as-is"
    fi
fi

# --- Server: restore visit history (must happen before the restart below, same reason
# as in 03-deploy-mods.sh: VisitedTraderStore only reads this file on world load) ---
DATA_BACKUP="$OUTPUT_DIR/server-data-backup.json"
DATA_PATH_FILE="$OUTPUT_DIR/server-data-path.txt"
if [ -f "$DATA_BACKUP" ] && [ -f "$DATA_PATH_FILE" ]; then
    DATA_FILE="$(cat "$DATA_PATH_FILE")"
    log "restoring visit history to $DATA_FILE..."
    cp -f "$DATA_BACKUP" "$DATA_FILE" || log "warn: failed to restore visit history (continuing)"
else
    log "no visit-history backup found; nothing to restore (world had none before this run)"
fi

# --- Server: restart (to confirm restore) then stop ---
docker_server_restart || log "warn: failed to restart Docker server (continuing)"
docker_server_wait_mod_loaded 60 || log "warn: mod-loaded confirmation after restore failed (continuing)"
docker_server_stop || log "warn: failed to stop Docker server"

log "teardown complete"
