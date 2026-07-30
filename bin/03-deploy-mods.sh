#!/usr/bin/env bash
# Backs up the current mods and deploys the Debug builds (from output/<profile>/) to
# both the Docker server and the Windows client, then restarts the server so the new
# mod loads.
#
# Client-side backups are stashed under OMEN_SCRATCH_DIR (NOT under Mods\ itself) and
# restored from there in 07-teardown.sh - see docs/lessons-learned.md on why a backup
# living inside a ModLauncherV5-managed Mods\ folder can get silently overwritten.
#
# Usage: 03-deploy-mods.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"
# shellcheck source=lib/docker-server.sh
source "$ROOT_DIR/lib/docker-server.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"

for var in SERVER_MODS_DIR CLIENT_MODS_DIR VTT_CLIENT_MOD_DIRNAME OMEN_SCRATCH_DIR; do
    require_var "$var"
done

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
[ -f "$OUTPUT_DIR/SdtdTestPilot.debug.dll" ] || die "missing $OUTPUT_DIR/SdtdTestPilot.debug.dll (run 02-build-mods.sh first)"

# VTT_RELEASE_PACKAGE deploys the mod under test straight out of a released ZIP instead of
# the Debug build. That is the only way to test what users actually download: the Debug
# build exists solely because `vtttest` needs it, and the shipped Release build has no
# harness at all. Driving it needs `testpilot dialog` instead - see docs/overview.md.
#
# SdtdTestPilot itself stays a Debug build either way; it is the test driver, not the mod
# under test.
VTT_RELEASE_PACKAGE="${VTT_RELEASE_PACKAGE:-}"
if [ -n "$VTT_RELEASE_PACKAGE" ]; then
    [ -f "$VTT_RELEASE_PACKAGE" ] || die "VTT_RELEASE_PACKAGE not found: $VTT_RELEASE_PACKAGE"
    require_cmd unzip
    RELEASE_DIR="$OUTPUT_DIR/release-mod"
    rm -rf "$RELEASE_DIR"
    mkdir -p "$RELEASE_DIR"
    unzip -q "$VTT_RELEASE_PACKAGE" -d "$RELEASE_DIR" || die "failed to extract $VTT_RELEASE_PACKAGE"
    VTT_SRC_DIR="$RELEASE_DIR/VisitedTraderTeleport"
    [ -f "$VTT_SRC_DIR/VisitedTraderTeleport.dll" ] \
        || die "$VTT_RELEASE_PACKAGE does not contain VisitedTraderTeleport/VisitedTraderTeleport.dll"
    VTT_DLL_SRC="$VTT_SRC_DIR/VisitedTraderTeleport.dll"
    VTT_CONFIG_SRC="$VTT_SRC_DIR/Config"
    VTT_DEPLOY_LABEL="released package $(basename "$VTT_RELEASE_PACKAGE")"
    DEPLOY_TEST_HARNESS=0
else
    [ -f "$OUTPUT_DIR/VisitedTraderTeleport.debug.dll" ] || die "missing $OUTPUT_DIR/VisitedTraderTeleport.debug.dll (run 02-build-mods.sh first)"
    [ -d "$OUTPUT_DIR/mod-config" ] || die "missing $OUTPUT_DIR/mod-config (run 02-build-mods.sh first)"
    VTT_DLL_SRC="$OUTPUT_DIR/VisitedTraderTeleport.debug.dll"
    VTT_CONFIG_SRC="$OUTPUT_DIR/mod-config"
    VTT_DEPLOY_LABEL="Debug build"
    DEPLOY_TEST_HARNESS=1
fi

# --- Server side (direct filesystem access, this machine) ---
SERVER_VTT_DIR="$SERVER_MODS_DIR/VisitedTraderTeleport"
[ -d "$SERVER_VTT_DIR" ] || die "server mod dir not found: $SERVER_VTT_DIR"

SERVER_BACKUP_DIR="$OUTPUT_DIR/server-mod-backup"
log "backing up server-side VisitedTraderTeleport to $SERVER_BACKUP_DIR..."
rm -rf "$SERVER_BACKUP_DIR"
cp -a "$SERVER_VTT_DIR" "$SERVER_BACKUP_DIR"

log "deploying VisitedTraderTeleport (${VTT_DEPLOY_LABEL}) to the server..."
cp "$VTT_DLL_SRC" "$SERVER_VTT_DIR/VisitedTraderTeleport.dll"
if [ "$DEPLOY_TEST_HARNESS" = "1" ]; then
    : > "$SERVER_VTT_DIR/EnableTestHarness.txt"
else
    # A Release build ignores the marker, but leaving a stale one behind would misrepresent
    # what was installed to anyone reading the directory afterwards.
    rm -f "$SERVER_VTT_DIR/EnableTestHarness.txt"
fi

# Deploy the built Config/ too, not just the DLL - otherwise a Localization.csv or
# dialogs.xml change is never actually loaded and the run silently verifies the previously
# installed copy. The whole server mod dir was copied to SERVER_BACKUP_DIR above, so
# teardown's restore already covers this.
log "deploying VisitedTraderTeleport Config/ to the server..."
mkdir -p "$SERVER_VTT_DIR/Config"
cp -rf "$VTT_CONFIG_SRC/." "$SERVER_VTT_DIR/Config/"

# Reset visit history so vtttest record's canonicalized-key resolution is deterministic.
# VisitedTraderTeleport merges a new visit into an existing destination when it falls
# within an already-recorded trader area, so a world with leftover visit history from
# earlier test runs can make a "new" record silently attach to a stale key instead of
# the trader actually visited. Must happen before the restart below - VisitedTraderStore
# only reads this file on world load, so editing it while the world is already loaded
# wouldn't take effect.
#
# IMPORTANT: match on GAME_SAVE_NAME (the exact save-slot name, i.e. sdtdserver.xml's
# GameName), NOT "most recently modified file under SERVER_SAVES_DIR". This machine's
# Saves directory accumulates data from every world ever tested here, and a brand-new
# world (whose own data file doesn't exist yet on its very first run) would otherwise
# make find fall back to whatever unrelated world's file happens to be newest - which
# silently reset a DIFFERENT world's visit history in testing. The world-name path
# segment is left as a wildcard because RWG world names are seed-derived and not known
# ahead of time; the save (game) name is the one value this tool actually controls.
require_var SERVER_SAVES_DIR
require_var GAME_SAVE_NAME
# Follows 01-start-server.sh's --fresh-save throwaway save when there is one.
SAVE_NAME="$(effective_game_save_name "$OUTPUT_DIR")"
DATA_FILE="$(find "$SERVER_SAVES_DIR" -path "*/${SAVE_NAME}/VisitedTraderTeleportData.json" 2>/dev/null | head -1)"
if [ -n "$DATA_FILE" ]; then
    log "backing up and clearing visit history ($DATA_FILE) for a deterministic run..."
    cp "$DATA_FILE" "$OUTPUT_DIR/server-data-backup.json"
    printf '%s' "$DATA_FILE" > "$OUTPUT_DIR/server-data-path.txt"
    rm -f "$DATA_FILE"
else
    log "no existing visit history found; nothing to reset"
    rm -f "$OUTPUT_DIR/server-data-backup.json" "$OUTPUT_DIR/server-data-path.txt"
fi

docker_server_restart
docker_server_wait_mod_loaded 60
# The mod appearing in "Loaded Mod: ..." only means the mod list parsed - the world
# itself (createWorld -> StartGame done) takes much longer and a client that connects
# before that finishes gets rejected ("still initializing the server").
docker_server_wait_started 300

# --- Client side (SSH, omen-build) ---
CLIENT_VTT_DIR="${CLIENT_MODS_DIR}\\${VTT_CLIENT_MOD_DIRNAME}"
CLIENT_BACKUP_DIR="${OMEN_SCRATCH_DIR}\\mod-backup"

log "backing up client-side VisitedTraderTeleport to $OMEN_SSH_HOST:$CLIENT_BACKUP_DIR..."
run_on_omen_cmd "New-Item -ItemType Directory -Force -Path '${CLIENT_BACKUP_DIR}' | Out-Null; Copy-Item '${CLIENT_VTT_DIR}\\VisitedTraderTeleport.dll' '${CLIENT_BACKUP_DIR}\\VisitedTraderTeleport.dll.orig' -Force"

# Unlike the server side (whose whole mod dir is copied to SERVER_BACKUP_DIR above), the
# client backup is file-by-file, so Config/ needs its own copy before it is overwritten.
run_on_omen_cmd "Remove-Item '${CLIENT_BACKUP_DIR}\\Config.orig' -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path '${CLIENT_VTT_DIR}\\Config') { Copy-Item '${CLIENT_VTT_DIR}\\Config' '${CLIENT_BACKUP_DIR}\\Config.orig' -Recurse -Force }"

log "deploying VisitedTraderTeleport (${VTT_DEPLOY_LABEL}) to the client..."
copy_to_omen "$VTT_DLL_SRC" "${CLIENT_VTT_DIR}\\VisitedTraderTeleport.dll"
if [ "$DEPLOY_TEST_HARNESS" = "1" ]; then
    run_on_omen_cmd "New-Item -ItemType File -Force -Path '${CLIENT_VTT_DIR}\\EnableTestHarness.txt' | Out-Null"
else
    run_on_omen_cmd "Remove-Item '${CLIENT_VTT_DIR}\\EnableTestHarness.txt' -Force -ErrorAction SilentlyContinue"
fi

log "deploying VisitedTraderTeleport Config/ to the client..."
run_on_omen_cmd "New-Item -ItemType Directory -Force -Path '${CLIENT_VTT_DIR}\\Config' | Out-Null"
copy_dir_to_omen "$VTT_CONFIG_SRC" "${CLIENT_VTT_DIR}\\Config"

log "deploying SdtdTestPilot to the client..."
CLIENT_TESTPILOT_DIR="${CLIENT_MODS_DIR}\\SdtdTestPilot"
run_on_omen_cmd "New-Item -ItemType Directory -Force -Path '${CLIENT_TESTPILOT_DIR}' | Out-Null"
copy_to_omen "$OUTPUT_DIR/SdtdTestPilot.debug.dll" "${CLIENT_TESTPILOT_DIR}\\SdtdTestPilot.dll"
copy_to_omen "$OUTPUT_DIR/SdtdTestPilot.ModInfo.xml" "${CLIENT_TESTPILOT_DIR}\\ModInfo.xml"
run_on_omen_cmd "New-Item -ItemType File -Force -Path '${CLIENT_TESTPILOT_DIR}\\EnableTestPilot.txt' | Out-Null"

log "mods deployed"
