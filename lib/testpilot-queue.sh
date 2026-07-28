#!/usr/bin/env bash
# Wrappers around SdtdTestPilot's file-based command queue protocol (see
# docs/HeadlessTestDriver.md). All queue paths are Windows paths on OMEN_SSH_HOST.
# Requires config var OMEN_QUEUE_DIR. Source after lib/common.sh and lib/ssh-omen.sh.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# testpilot_wait_ready [timeout_seconds]: blocks until <OMEN_QUEUE_DIR>\READY exists.
testpilot_wait_ready() {
    require_var OMEN_QUEUE_DIR
    local timeout="${1:-300}"
    local waited=0
    log "waiting for SdtdTestPilot READY marker (timeout ${timeout}s)..."
    while true; do
        if run_on_omen_cmd "if (Test-Path '${OMEN_QUEUE_DIR}\\READY') { exit 0 } else { exit 1 }" >/dev/null 2>&1; then
            log "READY marker found"
            return 0
        fi
        if [ "$waited" -ge "$timeout" ]; then
            die "timed out waiting for READY marker in $OMEN_QUEUE_DIR"
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

# testpilot_submit <id> <command text>: submits one console command through the queue
# and prints the single-line result JSON to stdout.
#
# Invoke-TestPilotCmd.ps1 hands the result back base64-encoded ("B64 <payload>") so the
# game's own UTF-8 bytes survive the Japanese-locale Windows host and the SSH hop intact -
# see the comment in that script. Anything else (notably "TIMEOUT ...") is passed through
# unchanged so callers can keep matching on it.
testpilot_submit() {
    require_var OMEN_QUEUE_DIR
    local id="$1"
    local command="$2"
    local raw
    raw="$(run_on_omen_script "$LIB_DIR/windows/Invoke-TestPilotCmd.ps1" \
        -Id "$id" -Command "\"$command\"" -QueueDir "\"$OMEN_QUEUE_DIR\"")"

    if printf '%s' "$raw" | grep -q '^B64 '; then
        printf '%s' "$raw" | grep '^B64 ' | head -1 | cut -d' ' -f2- | tr -d '\r\n ' | base64 -d
    else
        printf '%s' "$raw"
    fi
}

# next_id: a nanosecond timestamp, not an incrementing counter. submit_and_check calls
# this inside a command substitution `$(...)`, which runs in a subshell - a counter
# variable incremented there would never be visible to the parent shell, so every call
# would silently return the same id and every command after the first would read back a
# stale out/<id>.result file instead of waiting for its own.
next_id() {
    date +%s%N
}

# submit_and_check <command text>: submits through the queue, dies on a queue-level
# timeout, prints the raw single-line result JSON.
submit_and_check() {
    local cmd="$1"
    local result
    result="$(testpilot_submit "$(next_id)" "$cmd")"
    if [[ "$result" == TIMEOUT* ]]; then
        die "command queue timed out submitting: $cmd"
    fi
    printf '%s' "$result"
}

# vtt_result_field <result_json> <field name>: pulls a field out of the VTT_TEST_RESULT /
# TESTPILOT_RESULT marker embedded in .output (not the outer .ok, which only reflects
# whether SdtdConsole.ExecuteSync threw).
# The trailing `|| true` matters: with pipefail, a grep that finds no match exits non-zero
# and would otherwise kill the calling script via `set -e` before it gets a chance to
# check whether the result was actually empty.
vtt_result_field() {
    local result_json="$1"
    local field="$2"
    printf '%s' "$result_json" | jq -r '.output' | grep -oP "\"${field}\":\"?\K[^\",}]+" | tail -1 || true
}

# testpilot_reset_queue: removes and recreates the queue dir (used before a fresh
# client launch so stale in/out/processed files from a prior run don't confuse things).
testpilot_reset_queue() {
    require_var OMEN_QUEUE_DIR
    run_on_omen_cmd "Remove-Item '${OMEN_QUEUE_DIR}' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '${OMEN_QUEUE_DIR}' | Out-Null"
}
