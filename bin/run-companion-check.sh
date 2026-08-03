#!/usr/bin/env bash
# Runs the companion scenario end to end and always tears down, even when it fails.
#
# The scenario itself is worth a driver rather than a hand-assembled chain of stage scripts:
# the first attempt was run as `bash -c 'set -e; 01; 03; 05c; 06c; 07'`, the verification
# failed, and `set -e` took the shell out before teardown - leaving a server up, a client
# running and the Debug mod still deployed. An EXIT trap is the whole difference.
#
# --fresh-save is the default here, unlike the other drivers. The scenario asserts the player
# is alive at both ends, and a save carrying a character an earlier run got killed fails it
# before anything interesting happens.
#
# Both topologies are worth running. Travel takes a different branch for a local player than
# for a remote one - `if (player is EntityPlayerLocal)` in VisitedTraderTeleportService - and
# each branch has its own GatherCompanions call site with a different centre. A run against
# the dedicated server leaves the single-player path untested, and vice versa.
#
# Usage: run-companion-check.sh --profile <v3|v26> [--mode connect|hostload]
#                               [--package <zip>] [--keep-save] [--persistent-save]
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

usage() {
    cat <<EOF
Usage: $0 --profile <v3|v26> [--mode connect|hostload] [--package <zip>]
            [--keep-save] [--persistent-save]

Spawns a stand-in companion and a turret, marks them the way SCore and a placed turret do,
travels, and checks that the companion was gathered and the turret was not.

  --profile <name>     Which config/<name>.env to run against.
  --package <zip>      Install the mod under test from a released ZIP instead of building it
                       Debug. The markers this scenario needs come from SdtdTestPilot, which
                       is a separate mod, so the whole check runs against exactly what users
                       download. Without this the check only ever sees a Debug build.
  --mode <topology>    connect (default) joins the Docker dedicated server, so the world
                       lives in the server process. hostload has the client host the world
                       itself, with no server - which is the single-player travel path, and
                       a different branch of the code.
  --persistent-save    Use the profile's normal save instead of a throwaway one. Only useful
                       for reproducing something on an existing world; the scenario needs a
                       living player, and a persistent save may not have one.
  --keep-save          Keep the throwaway save afterwards, for post-mortem inspection.

Results land in output/<profile>/companion-result.json and companion-verify.json, plus a
screenshot under screenshots/companion/ if the scenario fails.
EOF
}

PROFILE=""
MODE="connect"
PACKAGE=""
FRESH_SAVE=1
KEEP_SAVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --package) PACKAGE="${2:-}"; shift 2 ;;
        --persistent-save) FRESH_SAVE=0; shift ;;
        --keep-save) KEEP_SAVE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$PROFILE" ] || { usage; die "--profile is required"; }
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

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
# Drop the previous verdict so a run that dies early cannot be read as the last run's pass.
rm -f "$OUTPUT_DIR/companion-result.json" "$OUTPUT_DIR/companion-verify.json"
rm -rf "$OUTPUT_DIR/screenshots/companion"

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
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/04-launch-client.sh" "$PROFILE" || STEP_STATUS="launch-client failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/05c-run-companion-scenario.sh" "$PROFILE" || STEP_STATUS="companion scenario failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/06c-verify-companions.sh" "$PROFILE" || STEP_STATUS="companion verification failed"
fi
[ "$STEP_STATUS" = "unknown" ] && STEP_STATUS="ok"

VERDICT="null"
[ -f "$OUTPUT_DIR/companion-verify.json" ] && VERDICT="$(cat "$OUTPUT_DIR/companion-verify.json")"

if command -v jq >/dev/null 2>&1; then
    SUMMARY="$(jq -n --arg profile "$PROFILE" --arg status "$STEP_STATUS" --argjson verdict "$VERDICT" \
        '{profile: $profile, status: $status, verdict: $verdict}')"
else
    SUMMARY="{\"profile\":\"$PROFILE\",\"status\":\"$STEP_STATUS\"}"
fi
echo "COMPANION_CHECK_RESULT $SUMMARY"

[ "$STEP_STATUS" = "ok" ]
