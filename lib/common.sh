#!/usr/bin/env bash
# Shared logging/error helpers for all bin/*.sh scripts. Source this, don't execute it.

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
    done
}

# trace_errors: makes `set -e` deaths visible. Call it once, right after sourcing the
# libs, from any script that runs under `set -e`.
#
# Without it, a command that fails somewhere other than an explicit `die` ends the script
# with no output whatsoever, which is indistinguishable from a clean early return. That
# is not hypothetical: 01-start-server.sh once died 121s into a 480s wait, printing
# nothing at all, and there was simply nothing left to diagnose it with. `set -E` is
# required so the trap also fires for failures inside library functions.
trace_errors() {
    set -E
    trap 'log "ERROR: ${BASH_SOURCE[0]:-?}:${LINENO} failed (exit $?): ${BASH_COMMAND}"' ERR
}

# effective_game_save_name <output_dir>: the save slot this run actually uses.
#
# Normally that is the profile's GAME_SAVE_NAME (a persistent save reused across runs).
# With --fresh-save, 01-start-server.sh points the server at a throwaway save instead and
# records its name in <output_dir>/fresh-save-name.txt; every later step has to follow it
# there, or it would look for this run's data in the persistent save and find nothing (or
# worse, find the *previous* run's data and verify against that).
effective_game_save_name() {
    local fresh_file="$1/fresh-save-name.txt"
    if [ -s "$fresh_file" ]; then
        cat "$fresh_file"
    else
        printf '%s' "${GAME_SAVE_NAME:-}"
    fi
}

# hold_profile_lock <profile>: refuses to start when another run is already using this
# profile's output directory.
#
# Two runs against one profile do not fail loudly, they corrupt each other's answers. That is
# not hypothetical: a release verification was started while the previous run's teardown was
# still finishing, the old teardown deleted the new run's fresh-save-name.txt on its way out,
# and the travel check then looked for this run's visit records in the *persistent* save and
# reported the package broken. The travel had actually worked.
#
# The lock is held by keeping a file descriptor open, so it is released when the process exits
# for any reason - including being killed - without needing a trap.
hold_profile_lock() {
    local profile="$1"
    local lock_dir="${ROOT_DIR:?}/output/${profile}"
    mkdir -p "$lock_dir"
    exec 9>"${lock_dir}/.run.lock"
    if ! flock -n 9; then
        # Queue rather than fail. Runs are usually started back to back, and the thing being
        # waited on is normally the previous run's teardown - a minute at most. Failing there
        # just means starting it again by hand.
        log "waiting for the current run on profile '${profile}' to finish..."
        flock -w 1800 9 || die "timed out waiting for the run on profile '${profile}' to finish"
    fi
}

# hold_dedicated_server_lock: serialises everything that starts the Docker dedicated server.
#
# hold_profile_lock is not enough. The two profiles are different servers with different
# compose files, but they publish the *same host ports*, so only one of them can run at a
# time. Starting the v2.6 server while the v3.0 one was still shutting down failed with
#
#   Error response from daemon: failed to set up container networking: driver failed
#   programming external connectivity on endpoint 7dtdserver-v26-wasteland
#
# which reads like a Docker problem rather than "something else is using the ports". Teardown
# restarts the server on its way out, so the window is wider than the run itself.
hold_dedicated_server_lock() {
    local lock_dir="${ROOT_DIR:?}/output"
    mkdir -p "$lock_dir"
    exec 8>"${lock_dir}/.dedicated-server.lock"
    if ! flock -n 8; then
        log "waiting for the dedicated server to be free (another profile is using it)..."
        flock -w 900 8 || die "timed out waiting for the dedicated server to be free"
    fi
}

# Redacts values that look like secrets before they hit logs. Currently a no-op
# passthrough for IPs/paths (not secret, just environment-specific) but kept as
# a single choke point in case a profile ever needs a real secret.
mask() {
    printf '%s' "$1"
}

require_var() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        die "required config variable is not set: $name (check your config/<profile>.env)"
    fi
}

load_profile() {
    local profile="$1"
    local config_dir
    config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config"
    local env_file="$config_dir/${profile}.env"
    [ -f "$env_file" ] || die "no such profile: $profile (expected $env_file)"
    # shellcheck disable=SC1090
    source "$env_file"
    log "loaded profile '$profile' from $env_file"
}
