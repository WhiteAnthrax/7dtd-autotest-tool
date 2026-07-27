#!/usr/bin/env bash
# SSH wrappers for the Windows build/test host (config var OMEN_SSH_HOST, resolved via
# ~/.ssh/config on this machine). Source this after lib/common.sh, don't execute it.
#
# Lesson learned the hard way (see docs/lessons-learned.md): never build multi-line or
# variable-heavy PowerShell commands as an inline `ssh host "powershell -Command ..."`
# string. Local bash quoting and remote Japanese-locale output both corrupt it easily.
# Always write the PowerShell to a temp .ps1 file and run it with -File instead.

# run_on_omen_cmd <one-line PowerShell expression>
# For short, quote-free one-liners only (Test-Path, Get-Process, etc.).
run_on_omen_cmd() {
    require_var OMEN_SSH_HOST
    # shellcheck disable=SC2029 # intentional: $1 is meant to expand client-side into the remote command string
    ssh "$OMEN_SSH_HOST" "powershell.exe -NoProfile -NonInteractive -Command \"$1\""
}

# run_on_omen_script <local .ps1 path> [args passed through to the script]
# Copies the script to a fixed remote scratch dir and runs it with -File, so quoting
# and encoding issues never make it across the SSH boundary.
#
# IMPORTANT: -File args are parsed by Win32 command-line rules (like cmd.exe), NOT by
# PowerShell's own parser - single quotes are NOT special there and will end up as
# literal characters, splitting "'C:\Some Path\x'" into two arguments at the space.
# Any argument value that can contain a space (paths, etc.) MUST be wrapped in escaped
# double quotes by the caller, e.g.: -ProjectPath "\"$path\"" - not -ProjectPath "'$path'".
run_on_omen_script() {
    require_var OMEN_SSH_HOST
    require_var OMEN_SCRATCH_DIR
    local local_script="$1"
    shift
    local remote_name
    remote_name="$(basename "$local_script")"
    local remote_path="${OMEN_SCRATCH_DIR}\\${remote_name}"

    run_on_omen_cmd "New-Item -ItemType Directory -Force -Path '${OMEN_SCRATCH_DIR}' | Out-Null"
    scp -q "$local_script" "${OMEN_SSH_HOST}:${remote_path//\\//}"
    # shellcheck disable=SC2029 # intentional: $remote_path/$* are meant to expand client-side into the remote command string
    ssh "$OMEN_SSH_HOST" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$remote_path\" $*"
}

# copy_to_omen <local_path> <remote_windows_path>
copy_to_omen() {
    require_var OMEN_SSH_HOST
    scp -q "$1" "${OMEN_SSH_HOST}:${2//\\//}"
}

# copy_from_omen <remote_windows_path> <local_path>
copy_from_omen() {
    require_var OMEN_SSH_HOST
    scp -q "${OMEN_SSH_HOST}:${1//\\//}" "$2"
}
