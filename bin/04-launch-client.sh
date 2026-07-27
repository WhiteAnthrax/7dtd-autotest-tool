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

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"

for var in CLIENT_GAME_PATH CLIENT_EXE_NAME OMEN_TASK_NAME OMEN_USER_ID OMEN_QUEUE_DIR SERVER_IP SERVER_PORT; do
    require_var "$var"
done
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"

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

testpilot_wait_ready "$READY_TIMEOUT_SECONDS"
log "client is connected and the command queue is ready"
