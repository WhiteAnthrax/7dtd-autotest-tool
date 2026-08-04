#!/usr/bin/env bash
# Judges the long-distance trip recorded by 05d-run-distance-travel-scenario.sh.
#
# The point of the scenario is the preparation path, so "the player ended up somewhere else"
# is not enough on its own: a trip that skipped preparation would also move the player. The
# markers below are the mod's own account of having done the work, and they are only produced
# when the destination was not already loaded.
#
# Usage: 06d-verify-distance-travel.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
RESULT_FILE="$OUTPUT_DIR/distance-travel-result.json"
VERDICT_FILE="$OUTPUT_DIR/distance-travel-verify.json"
rm -f "$VERDICT_FILE"
[ -f "$RESULT_FILE" ] || die "no $RESULT_FILE - run 05d-run-distance-travel-scenario.sh first"

jq '{
    mode,
    requested_distance,
    separation_before,
    travelled,
    arrival_offset,
    travel_seconds,
    confirmation,
    markers,
    player_alive: (.player.end.dead | not),

    # The trip really was long. Without this the whole scenario could pass on a 0m hop.
    was_a_long_trip: (.separation_before >= (.requested_distance * 0.8)),

    # Preparation ran, finished, and did not give up. "Destination was not ready after
    # preparation" is the failure this scenario exists to catch.
    preparation_ran: (.markers.preparation_started >= 1),
    preparation_completed: (.markers.preparation_ready >= 1),
    preparation_did_not_fail: (.markers.preparation_failed == 0),

    # The travel queue neither expired a request nor failed to start one. Both of those are
    # the freeze symptoms 0.6.20 addressed.
    #
    # Only the problems are asserted. "Starting queued transport" is logged solely when a
    # request actually waited behind another one, so a single trip never produces it and
    # requiring it failed a run that was in fact perfect. Reaching the serialization path on
    # purpose needs two overlapping trips - worth a scenario of its own, not a check here.
    no_queue_problems: (.markers.queue_problems == 0),

    travelled_the_distance: (.travelled >= (.requested_distance * 0.8)),
    arrived_at_the_destination: (.arrival_offset <= .arrival_tolerance),
    teleport_reported: (.markers.teleported == 1),
    no_teleport_failure: (.markers.teleport_failed == 0),
    screenshots: (.screenshots | length),
    screenshot_dir
}
| .ok = (.player_alive and .was_a_long_trip and .preparation_ran and .preparation_completed
         and .preparation_did_not_fail and .no_queue_problems
         and .travelled_the_distance and .arrived_at_the_destination and .teleport_reported
         and .no_teleport_failure)' \
    "$RESULT_FILE" > "$VERDICT_FILE"

jq -r '
    "distance travel verdict (" + .mode + "):",
    "  trip:        \(.separation_before)m away, moved \(.travelled)m, ended \(.arrival_offset)m from the destination",
    "  took:        \(.travel_seconds)s",
    "  preparation: started=\(.markers.preparation_started) ready=\(.markers.preparation_ready) not_ready=\(.markers.preparation_failed)",
    "  transport:   started=\(.markers.transport_started) problems=\(.markers.queue_problems) teleported=\(.markers.teleported) failed=\(.markers.teleport_failed)",
    "  player:      " + (if .player_alive then "alive" else "DEAD" end)' "$VERDICT_FILE"

if [ "$(jq -r '.ok' "$VERDICT_FILE")" != "true" ]; then
    jq -r 'to_entries[] | select(.value == false) | "  FAILED: \(.key)"' "$VERDICT_FILE"
    die "long-distance travel verification failed (see $VERDICT_FILE)"
fi

log "long-distance travel verification passed"
