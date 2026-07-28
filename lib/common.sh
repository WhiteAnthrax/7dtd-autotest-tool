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
