#!/usr/bin/env bash
# Stopping the Windows game client. Shared by 07-teardown.sh, which stops it as part of
# putting the machine back, and run-language-sweep.sh, which has to stop and relaunch it
# once per language because the UI language is fixed at launch.
# Requires config vars CLIENT_EXE_NAME and OMEN_TASK_NAME. Source after lib/common.sh and
# lib/ssh-omen.sh.

CLIENT_CONTROL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# stop_client: stops the client process and its scheduled task. Deliberately never fatal -
# both callers have work left to do afterwards, and a client that is already gone is the
# state we wanted anyway.
stop_client() {
    if [ -z "${CLIENT_EXE_NAME:-}" ] || [ -z "${OMEN_TASK_NAME:-}" ]; then
        log "warn: CLIENT_EXE_NAME/OMEN_TASK_NAME not set, skipping client stop"
        return 0
    fi
    log "stopping client process/task..."
    run_on_omen_script "$CLIENT_CONTROL_LIB_DIR/windows/Stop-TestPilotClient.ps1" \
        -ProcessName "\"${CLIENT_EXE_NAME%.exe}\"" -TaskName "\"${OMEN_TASK_NAME}\"" \
        || log "warn: failed to stop client process/task (continuing)"
}
