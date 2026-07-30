#!/usr/bin/env bash
# Checks output/<profile>/release-travel-result.json - the travel 05t ran on the packaged
# Release build.
#
# Usage: 06t-verify-release-travel.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
RESULT_FILE="$OUTPUT_DIR/release-travel-result.json"
[ -f "$RESULT_FILE" ] || die "missing $RESULT_FILE (run 05t-run-release-travel-scenario.sh first)"

VERIFY_FILE="$OUTPUT_DIR/release-travel-verify.json"

# The server-side counts are the load-bearing ones: they come from the server rather than
# from the build under test reporting on itself. A trip that never happened, or one that
# threw on the way, cannot produce "Teleported" with no failure and no exception.
VERDICT="$(jq '
    {
        travelled: (.server.teleported >= 1),
        no_teleport_failure: (.server.teleport_failed == 0),
        no_server_exceptions: (.server.exceptions == 0),
        destination: .destination_text,
        confirmation: .confirmation,
        recorded_keys: (.recorded_keys | length),
        expected_recorded_keys: .expected_recorded_keys,
        keys_recorded_as_expected: ((.recorded_keys | length) == .expected_recorded_keys),
        player_alive: ((.player.before.dead | not) and (.player.after.dead | not)),
        screenshots: (.screenshots | length)
    }
    | .ok = (
        .travelled
        and .no_teleport_failure
        and .no_server_exceptions
        and .keys_recorded_as_expected
        and .player_alive
      )
' "$RESULT_FILE")"

printf '%s\n' "$VERDICT" > "$VERIFY_FILE"
OK="$(printf '%s' "$VERDICT" | jq -r '.ok')"

if [ "$OK" != "true" ]; then
    log "release travel verification FAILED:"
    printf '%s\n' "$VERDICT"
    die "release travel verification failed (details in $VERIFY_FILE)"
fi

log "release travel verification passed: $(printf '%s' "$VERDICT" | jq -r '"destination=\(.destination) keys=\(.recorded_keys) confirmation=\(.confirmation)"')"
