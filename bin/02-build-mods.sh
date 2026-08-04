#!/usr/bin/env bash
# Builds Debug versions of VisitedTraderTeleport (with vtttest) and SdtdTestPilot on the
# Windows build host, then pulls the built DLLs back to output/<profile>/.
# Usage: 02-build-mods.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"

require_cmd git tar ssh scp
for var in VTT_REPO_PATH VTT_BRANCH TESTPILOT_REPO_PATH GAME_FLAVOR CLIENT_GAME_PATH; do
    require_var "$var"
done
[ -d "$VTT_REPO_PATH" ] || die "VTT_REPO_PATH does not exist: $VTT_REPO_PATH"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"

WORK_REMOTE_VTT="${OMEN_SCRATCH_DIR}\\vtt-build"
WORK_REMOTE_TESTPILOT="${OMEN_SCRATCH_DIR}\\testpilot-build"

# --- 1. VisitedTraderTeleport (Debug, vtttest included) ---
TMP_VTT_TAR=""
TMP_TESTPILOT_TAR=""
trap 'rm -f "$TMP_VTT_TAR" "$TMP_TESTPILOT_TAR"' EXIT

log "archiving VisitedTraderTeleport@$VTT_BRANCH..."
TMP_VTT_TAR="$(mktemp --suffix=.tar.gz)"
git -C "$VTT_REPO_PATH" archive "$VTT_BRANCH" | gzip > "$TMP_VTT_TAR"

log "transferring to $OMEN_SSH_HOST:$WORK_REMOTE_VTT..."
run_on_omen_cmd "Remove-Item '${WORK_REMOTE_VTT}' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '${WORK_REMOTE_VTT}' | Out-Null"
copy_to_omen "$TMP_VTT_TAR" "${WORK_REMOTE_VTT}\\vtt.tar.gz"
run_on_omen_cmd "tar -xzf '${WORK_REMOTE_VTT}\\vtt.tar.gz' -C '${WORK_REMOTE_VTT}'"

log "building VisitedTraderTeleport (Debug)..."
run_on_omen_script "$ROOT_DIR/lib/windows/Build-Mod.ps1" \
    -ProjectPath "\"${WORK_REMOTE_VTT}\\src\\VisitedTraderTeleport\\VisitedTraderTeleport.csproj\"" \
    -GamePath "\"${CLIENT_GAME_PATH}\"" \
    -RepositoryPath "\"${WORK_REMOTE_VTT}\""

copy_from_omen "${WORK_REMOTE_VTT}\\src\\VisitedTraderTeleport\\bin\\Debug\\VisitedTraderTeleport.dll" \
    "$OUTPUT_DIR/VisitedTraderTeleport.debug.dll"
log "VisitedTraderTeleport.debug.dll -> $OUTPUT_DIR"

# The mod's Config/ (Localization.csv, dialogs.xml, VisitedTraderTeleport.xml) travels with
# the DLL. Without this the pipeline would deploy a new DLL on top of whatever Config the
# client and server happened to already have installed, so a change to the localization
# file or the dialog definitions would be tested against the *old* copy and pass without
# ever having been loaded. Taken from the build tree, not the local checkout, so what gets
# deployed is exactly what was built.
log "collecting VisitedTraderTeleport Config/ from the build tree..."
copy_dir_from_omen "${WORK_REMOTE_VTT}\\mod\\VisitedTraderTeleport\\Config" "$OUTPUT_DIR/mod-config"
log "mod-config/ -> $OUTPUT_DIR"

# --- 2. SdtdTestPilot (Debug, matching GameFlavor) ---
log "archiving SdtdTestPilot (this repo)..."
TMP_TESTPILOT_TAR="$(mktemp --suffix=.tar.gz)"
git -C "$TESTPILOT_REPO_PATH" archive HEAD | gzip > "$TMP_TESTPILOT_TAR"

log "transferring to $OMEN_SSH_HOST:$WORK_REMOTE_TESTPILOT..."
run_on_omen_cmd "Remove-Item '${WORK_REMOTE_TESTPILOT}' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '${WORK_REMOTE_TESTPILOT}' | Out-Null"
copy_to_omen "$TMP_TESTPILOT_TAR" "${WORK_REMOTE_TESTPILOT}\\testpilot.tar.gz"
run_on_omen_cmd "tar -xzf '${WORK_REMOTE_TESTPILOT}\\testpilot.tar.gz' -C '${WORK_REMOTE_TESTPILOT}'"

log "building SdtdTestPilot (Debug, GameFlavor=$GAME_FLAVOR)..."
run_on_omen_script "$ROOT_DIR/lib/windows/Build-Mod.ps1" \
    -ProjectPath "\"${WORK_REMOTE_TESTPILOT}\\src\\SdtdTestPilot\\SdtdTestPilot.csproj\"" \
    -GamePath "\"${CLIENT_GAME_PATH}\"" \
    -RepositoryPath "\"${WORK_REMOTE_TESTPILOT}\"" \
    -GameFlavor "\"${GAME_FLAVOR}\""

copy_from_omen "${WORK_REMOTE_TESTPILOT}\\src\\SdtdTestPilot\\bin\\Debug\\SdtdTestPilot.dll" \
    "$OUTPUT_DIR/SdtdTestPilot.debug.dll"
copy_from_omen "${WORK_REMOTE_TESTPILOT}\\mod\\SdtdTestPilot\\ModInfo.xml" \
    "$OUTPUT_DIR/SdtdTestPilot.ModInfo.xml"
log "SdtdTestPilot.debug.dll -> $OUTPUT_DIR"

log "build complete"
