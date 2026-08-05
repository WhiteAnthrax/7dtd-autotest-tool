#!/usr/bin/env bash
# Runs one focused scenario end to end - server up, mods deployed, client launched, scenario,
# verdict - and always tears down, even when it fails.
#
# The stages are the same for every scenario; only the pair of scripts in the middle differs.
# This started as run-companion-check.sh and was generalised when the long-distance travel
# scenario needed exactly the same 120 lines around it. run-companion-check.sh is still there
# as a wrapper, because the runbook and muscle memory both name it.
#
# The teardown trap is the whole reason a driver exists rather than a chain of stage scripts:
# `bash -c 'set -e; 01; 03; 05c; 06c; 07'` left a server up, a client running and a Debug mod
# deployed the first time a verification failed.
#
# --fresh-save is the default here, unlike the roundtrip driver: these scenarios assert the
# player is alive, and a save carrying a character an earlier run got killed fails before
# anything interesting happens.
#
# Both topologies are worth running. Travel takes a different branch for a local player than
# for a remote one - `if (player is EntityPlayerLocal)` in VisitedTraderTeleportService - and
# a run against the dedicated server leaves the single-player path untested, and vice versa.
#
# Usage: run-scenario-check.sh --scenario <companion|distance|paging|cost> --profile <v3|v26>
#                              [--mode connect|hostload] [--package <zip>]
#                              [--keep-save] [--persistent-save]
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

usage() {
    cat <<EOF
Usage: $0 --scenario <companion|distance|paging|cost> --profile <v3|v26> [--mode connect|hostload]
            [--package <zip>] [--keep-save] [--persistent-save]

  --scenario <name>    Which scenario to run:
                         companion - spawns a hired companion and a placed turret, travels,
                                     and checks the companion came and the turret did not.
                         distance  - travels a real distance, so the destination has to be
                                     prepared first; checks that preparation ran and the
                                     arrival stabilized. TRAVEL_DISTANCE=<metres> to change
                                     how far (default 1000).
                         paging    - records seven traders so the destination list needs two
                                     pages, and walks them.
                         cost      - switches the travel cost on and checks that a trip is
                                     refused with nothing to pay with, and costs exactly the
                                     configured amount with. COST_ITEM / COST_PER_METER /
                                     COST_MINIMUM to change the terms.
  --profile <name>     Which config/<name>.env to run against.
  --package <zip>      Install the mod under test from a released ZIP instead of building it
                       Debug, so the check runs against exactly what users download.
  --mode <topology>    connect (default) joins the Docker dedicated server, so the world
                       lives in the server process. hostload has the client host the world
                       itself, with no server - the single-player path.
  --persistent-save    Use the profile's normal save instead of a throwaway one.
  --keep-save          Keep the throwaway save afterwards, for post-mortem inspection.

Results land in output/<profile>/<scenario>-*.json, plus screenshots under
output/<profile>/screenshots/<scenario>/.
EOF
}

SCENARIO=""
PREPARE_STAGE=""
PROFILE=""
MODE="connect"
PACKAGE=""
FRESH_SAVE=1
KEEP_SAVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --scenario) SCENARIO="${2:-}"; shift 2 ;;
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --package) PACKAGE="${2:-}"; shift 2 ;;
        --persistent-save) FRESH_SAVE=0; shift ;;
        --keep-save) KEEP_SAVE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
done
[ -n "$PROFILE" ] || { usage; die "--profile is required"; }

case "$SCENARIO" in
    companion) SCENARIO_STAGE="05c-run-companion-scenario.sh"; VERIFY_STAGE="06c-verify-companions.sh"
               RESULT_PREFIX="companion"; MARKER="COMPANION_CHECK_RESULT" ;;
    distance)  SCENARIO_STAGE="05d-run-distance-travel-scenario.sh"; VERIFY_STAGE="06d-verify-distance-travel.sh"
               RESULT_PREFIX="distance-travel"; MARKER="DISTANCE_CHECK_RESULT" ;;
    paging)    SCENARIO_STAGE="05p-run-paging-scenario.sh"; VERIFY_STAGE="06p-verify-paging.sh"
               RESULT_PREFIX="paging"; MARKER="PAGING_CHECK_RESULT" ;;
    cost)      SCENARIO_STAGE="05x-run-travel-cost-scenario.sh"; VERIFY_STAGE="06x-verify-travel-cost.sh"
               RESULT_PREFIX="travel-cost"; MARKER="COST_CHECK_RESULT"
               # The mod reads its config when the world loads, so the setting has to be in
               # place before the client starts - not when the scenario runs.
               PREPARE_STAGE="03c-configure-travel-cost.sh" ;;
    *) usage; die "--scenario must be companion, distance, paging or cost (got '${SCENARIO:-}')" ;;
esac

if [ "$KEEP_SAVE" = "1" ] && [ "$FRESH_SAVE" = "0" ]; then
    die "--keep-save only applies to the throwaway save; drop --persistent-save"
fi

case "$MODE" in
    connect|hostload) ;;
    *) die "--mode must be connect or hostload (got '$MODE')" ;;
esac
export TESTPILOT_MODE="$MODE"

if [ -n "$PACKAGE" ]; then
    [ -f "$PACKAGE" ] || die "package not found: $PACKAGE"
    VTT_RELEASE_PACKAGE="$(cd "$(dirname "$PACKAGE")" && pwd)/$(basename "$PACKAGE")"
    export VTT_RELEASE_PACKAGE
    log "checking the released package $(basename "$PACKAGE") rather than a Debug build"
fi

# The throwaway-save machinery rewrites the *dedicated server's* config, which hostload never
# reads - it hosts its own save under HOSTLOAD_GAME_NAME instead.
if [ "$MODE" = "hostload" ]; then
    FRESH_SAVE=0
    KEEP_SAVE=0
fi
export TESTPILOT_FRESH_SAVE="$FRESH_SAVE"
export TESTPILOT_KEEP_SAVE="$KEEP_SAVE"

hold_profile_lock "$PROFILE"
# Only connect mode uses the dedicated server - but teardown restarts it either way, so the
# lock is taken whenever this run will touch it at all.
[ "$MODE" = "connect" ] && hold_dedicated_server_lock
OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
# Drop the previous verdict so a run that dies early cannot be read as the last run's pass.
rm -f "$OUTPUT_DIR/${RESULT_PREFIX}-result.json" "$OUTPUT_DIR/${RESULT_PREFIX}-verify.json"
rm -rf "$OUTPUT_DIR/screenshots/${SCENARIO}"

cleanup() {
    local exit_code=$?
    log "running teardown (exit code so far: $exit_code)..."
    "$BIN_DIR/07-teardown.sh" "$PROFILE" || true
    exit "$exit_code"
}
trap cleanup EXIT

STEP_STATUS="unknown"
# No dedicated server in hostload mode - starting it would only bind the port the hosting
# client wants.
if [ "$MODE" = "connect" ]; then
    "$BIN_DIR/01-start-server.sh" "$PROFILE" || STEP_STATUS="start-server failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/02-build-mods.sh" "$PROFILE" || STEP_STATUS="build-mods failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/03-deploy-mods.sh" "$PROFILE" || STEP_STATUS="deploy-mods failed"
fi
if [ "$STEP_STATUS" = "unknown" ] && [ -n "$PREPARE_STAGE" ]; then
    "$BIN_DIR/$PREPARE_STAGE" "$PROFILE" || STEP_STATUS="${SCENARIO} preparation failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/04-launch-client.sh" "$PROFILE" || STEP_STATUS="launch-client failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/$SCENARIO_STAGE" "$PROFILE" || STEP_STATUS="${SCENARIO} scenario failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/$VERIFY_STAGE" "$PROFILE" || STEP_STATUS="${SCENARIO} verification failed"
fi
[ "$STEP_STATUS" = "unknown" ] && STEP_STATUS="ok"

VERDICT="null"
[ -f "$OUTPUT_DIR/${RESULT_PREFIX}-verify.json" ] && VERDICT="$(cat "$OUTPUT_DIR/${RESULT_PREFIX}-verify.json")"

if command -v jq >/dev/null 2>&1; then
    SUMMARY="$(jq -n --arg profile "$PROFILE" --arg status "$STEP_STATUS" --argjson verdict "$VERDICT" \
        '{profile: $profile, status: $status, verdict: $verdict}')"
else
    SUMMARY="{\"profile\":\"$PROFILE\",\"status\":\"$STEP_STATUS\"}"
fi
echo "$MARKER $SUMMARY"

[ "$STEP_STATUS" = "ok" ]
