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
