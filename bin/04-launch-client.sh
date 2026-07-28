#!/usr/bin/env bash
# Launches the client under SdtdTestPilot (connect mode) via Scheduled Tasks and waits
# for the command queue to become ready.
# Usage: 04-launch-client.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"
# shellcheck source=lib/testpilot-queue.sh
source "$ROOT_DIR/lib/testpilot-queue.sh"
# shellcheck source=lib/docker-server.sh
source "$ROOT_DIR/lib/docker-server.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"

for var in CLIENT_GAME_PATH CLIENT_EXE_NAME OMEN_TASK_NAME OMEN_USER_ID OMEN_QUEUE_DIR SERVER_IP SERVER_PORT; do
    require_var "$var"
done
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"

# Discord's ModEvents.MainMenuOpening handler returns StopHandlersAndVanilla - suppressing
# the vanilla main menu, and with it the MainMenuOpened event MainMenuTrigger waits on -
# unless Discord is disabled. See lib/windows/Set-DiscordDisabledPref.ps1 for the full
# mechanism, for why no launch argument can do this instead, and for why both the v3.x
# and the v2.6 storage formats have to be written. The backup lives in OMEN_SCRATCH_DIR
# rather than being passed back through argv, both because the v2.6 format is a JSON blob
# and to match how the client-side mod backup is handled in 03-deploy-mods.sh.
require_var OMEN_SCRATCH_DIR
DISCORD_PREF_BACKUP="${OMEN_SCRATCH_DIR}\\discord-pref-backup.json"
log "disabling Discord integration for this run..."
run_on_omen_script "$ROOT_DIR/lib/windows/Set-DiscordDisabledPref.ps1" \
    -Mode Apply -ExpectedUser "\"${OMEN_USER_ID}\"" -BackupPath "\"${DISCORD_PREF_BACKUP}\""

log "resetting command queue..."
testpilot_reset_queue

EXE_PATH="${CLIENT_GAME_PATH}\\${CLIENT_EXE_NAME}"
ARGS="-SkipNewsScreen=true -testpilot.mode=connect -testpilot.ip=${SERVER_IP} -testpilot.port=${SERVER_PORT} -testpilot.queue=${OMEN_QUEUE_DIR} -testpilot.readytimeout=${READY_TIMEOUT_SECONDS}"

log "launching client via scheduled task '$OMEN_TASK_NAME'..."
run_on_omen_script "$ROOT_DIR/lib/windows/Start-TestPilotClient.ps1" \
    -ExePath "\"${EXE_PATH}\"" \
    -Arguments "\"${ARGS}\"" \
    -WorkingDirectory "\"${CLIENT_GAME_PATH}\"" \
    -TaskName "\"${OMEN_TASK_NAME}\"" \
    -UserId "\"${OMEN_USER_ID}\""

# Check client vs server compatibility *before* settling in for the READY wait. The Docker
# server runs startserver-with-update.sh, so it quietly picks up new 7DTD releases while
# the client stays pinned to whatever was installed - and a mismatched client shows a
# version dialog and never connects, which from here is indistinguishable from any other
# hang. Catching it now turns a silent READY_TIMEOUT_SECONDS-long wait into an immediate,
# actionable error. Only a confirmed mismatch is fatal: if either version can't be read,
# say so and carry on rather than blocking a run that might be perfectly fine.
SERVER_COMPAT="$(docker_server_compat_version)"
CLIENT_COMPAT="$(run_on_omen_script "$ROOT_DIR/lib/windows/Get-ClientVersion.ps1" -TimeoutSeconds 60 \
    | tr -d '\r' | sed -n 's/^COMPATIBILITY //p' | head -1)"
if [ -z "$SERVER_COMPAT" ] || [ -z "$CLIENT_COMPAT" ]; then
    log "warn: could not determine both versions (server='${SERVER_COMPAT:-?}' client='${CLIENT_COMPAT:-?}'), skipping the compatibility check"
elif [ "$SERVER_COMPAT" != "$CLIENT_COMPAT" ]; then
    die "game version mismatch: server is V${SERVER_COMPAT}, client is V${CLIENT_COMPAT}. The client cannot join and would just hang at the version dialog. Update the client install at ${CLIENT_GAME_PATH} to V${SERVER_COMPAT} (or pin the server - see docs/runbook.md)."
else
    log "version check ok: server and client are both V${SERVER_COMPAT}"
fi

testpilot_wait_ready "$READY_TIMEOUT_SECONDS"
log "client is connected and the command queue is ready"
