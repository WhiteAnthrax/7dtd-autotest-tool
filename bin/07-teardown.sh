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
# shellcheck source=lib/client-control.sh
source "$ROOT_DIR/lib/client-control.sh"

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"

# --- Client: stop process/task ---
stop_client

# --- Client: restore the Discord settings ---
# Must run after the client has exited: the game writes its Discord settings back on
# shutdown, so restoring while it is still running would just get overwritten. The stop
# above already guarantees that ordering. The script no-ops if there is no backup, so a
# run that failed before 04-launch-client.sh leaves nothing stale behind.
if [ -n "${OMEN_USER_ID:-}" ] && [ -n "${OMEN_SCRATCH_DIR:-}" ]; then
    log "restoring Discord settings..."
    run_on_omen_script "$ROOT_DIR/lib/windows/Set-DiscordDisabledPref.ps1" \
        -Mode Restore -ExpectedUser "\"${OMEN_USER_ID}\"" \
        -BackupPath "\"${OMEN_SCRATCH_DIR}\\discord-pref-backup.json\"" \
        || log "warn: failed to restore Discord settings (continuing)"
else
    log "warn: OMEN_USER_ID/OMEN_SCRATCH_DIR not set, skipping Discord settings restore"
fi

# --- Client: restore mods ---
if [ -n "${CLIENT_MODS_DIR:-}" ] && [ -n "${VTT_CLIENT_MOD_DIRNAME:-}" ] && [ -n "${OMEN_SCRATCH_DIR:-}" ]; then
    CLIENT_VTT_DIR="${CLIENT_MODS_DIR}\\${VTT_CLIENT_MOD_DIRNAME}"
    CLIENT_BACKUP_DIR="${OMEN_SCRATCH_DIR}\\mod-backup"
    log "restoring client-side VisitedTraderTeleport from backup..."
    # Test-Path rather than -ErrorAction SilentlyContinue: that leaves $? false even though
    # it suppressed the error, so powershell.exe exits 1 and every teardown warned about a
    # restore that had nothing to do (see docs/lessons-learned.md).
    run_on_omen_cmd "if (Test-Path '${CLIENT_BACKUP_DIR}\\VisitedTraderTeleport.dll.orig') { Copy-Item '${CLIENT_BACKUP_DIR}\\VisitedTraderTeleport.dll.orig' '${CLIENT_VTT_DIR}\\VisitedTraderTeleport.dll' -Force } else { Write-Output 'NO_DLL_BACKUP' }; if (Test-Path '${CLIENT_VTT_DIR}\\EnableTestHarness.txt') { Remove-Item '${CLIENT_VTT_DIR}\\EnableTestHarness.txt' -Force }" \
        || log "warn: failed to restore client-side VisitedTraderTeleport (continuing)"

    # Config/ is deployed alongside the DLL by 03-deploy-mods.sh, so it has to be put back
    # too - otherwise the client keeps whatever localization/dialog files the last test run
    # happened to ship, which is exactly the drift this pipeline is supposed to avoid.
    log "restoring client-side VisitedTraderTeleport Config/ from backup..."
    run_on_omen_cmd "if (Test-Path '${CLIENT_BACKUP_DIR}\\Config.orig') { Remove-Item '${CLIENT_VTT_DIR}\\Config' -Recurse -Force -ErrorAction SilentlyContinue; Copy-Item '${CLIENT_BACKUP_DIR}\\Config.orig' '${CLIENT_VTT_DIR}\\Config' -Recurse -Force }" \
        || log "warn: failed to restore client-side Config/ (continuing)"

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
    # Unconditional: the driver mod is deployed whether or not there was a mod to back up,
    # and a run that ends before the backup is taken would otherwise leave it installed.
    if [ -d "${SERVER_MODS_DIR}/SdtdTestPilot" ]; then
        log "removing SdtdTestPilot from the server..."
        rm -rf "${SERVER_MODS_DIR}/SdtdTestPilot" \
            || log "warn: failed to remove server-side SdtdTestPilot (continuing)"
    fi

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

# --- Server: undo --fresh-save (config first, then the throwaway save itself) ---
# Deliberately after the server has stopped, so nothing rewrites the save while it is
# being removed.
SERVER_CONFIG="${DOCKER_COMPOSE_DIR:-}/data/serverfiles/sdtdserver.xml"
CONFIG_BACKUP="$OUTPUT_DIR/sdtdserver.xml.bak"
if [ -f "$CONFIG_BACKUP" ]; then
    log "restoring sdtdserver.xml from backup..."
    if cp -f "$CONFIG_BACKUP" "$SERVER_CONFIG"; then
        rm -f "$CONFIG_BACKUP"
    else
        log "warn: failed to restore $SERVER_CONFIG - the backup is kept at $CONFIG_BACKUP (continuing)"
    fi
fi

FRESH_SAVE_FILE="$OUTPUT_DIR/fresh-save-name.txt"
if [ -s "$FRESH_SAVE_FILE" ] && [ -n "${SERVER_SAVES_DIR:-}" ]; then
    FRESH_SAVE_NAME="$(cat "$FRESH_SAVE_FILE")"
    if [ "${TESTPILOT_KEEP_SAVE:-0}" = "1" ]; then
        log "keeping throwaway save '$FRESH_SAVE_NAME' (TESTPILOT_KEEP_SAVE=1); delete it yourself when done"
    # Only ever delete a directory this tool created. 01-start-server.sh writes this file
    # solely for names it generated, and they always carry the "Fresh<timestamp>" suffix -
    # re-checking that here means a hand-edited or truncated state file cannot turn this
    # into "rm -rf the persistent save".
    elif [[ "$FRESH_SAVE_NAME" == *Fresh[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] ]]; then
        while IFS= read -r save_dir; do
            [ -n "$save_dir" ] || continue
            log "removing throwaway save $save_dir..."
            rm -rf "$save_dir" || log "warn: failed to remove $save_dir (continuing)"
        done < <(find "$SERVER_SAVES_DIR" -mindepth 2 -maxdepth 2 -type d -name "$FRESH_SAVE_NAME" 2>/dev/null)
        rm -f "$FRESH_SAVE_FILE"
    else
        log "warn: '$FRESH_SAVE_NAME' does not look like a name this tool generated; refusing to delete it"
    fi
fi

log "teardown complete"
