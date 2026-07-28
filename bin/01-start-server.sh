#!/usr/bin/env bash
# Starts the Docker dedicated server and waits for the world to finish starting.
#
# Set TESTPILOT_FRESH_SAVE=1 (run-roundtrip.sh --fresh-save does this) to run against a
# throwaway save instead of the profile's persistent one. See the block below for what
# that does and does not reset.
#
# Usage: 01-start-server.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/docker-server.sh
source "$ROOT_DIR/lib/docker-server.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"

require_cmd docker
require_var DOCKER_COMPOSE_DIR
[ -d "$DOCKER_COMPOSE_DIR" ] || die "DOCKER_COMPOSE_DIR does not exist: $DOCKER_COMPOSE_DIR"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
SERVER_CONFIG="${DOCKER_COMPOSE_DIR}/data/serverfiles/sdtdserver.xml"

# Leftover state from an aborted run would make the later steps look in a save that is
# not the one this run is about to use.
rm -f "$OUTPUT_DIR/fresh-save-name.txt"

if [ "${TESTPILOT_FRESH_SAVE:-0}" = "1" ]; then
    # Only GameName is changed, not WorldGenSeed. GameName selects the save slot, so a new
    # one gives a brand-new, alive player and an empty visit history - which is the whole
    # point, since a player who died in an earlier run stays dead in the save and there is
    # no console command to revive them (see docs/lessons-learned.md). WorldGenSeed selects
    # the *terrain*; changing that too would force a full RWG generation costing tens of
    # minutes and several GB per run, and buys no additional determinism.
    require_var GAME_SAVE_NAME
    [ -f "$SERVER_CONFIG" ] || die "server config not found: $SERVER_CONFIG"

    FRESH_SAVE_NAME="${GAME_SAVE_NAME}Fresh$(date -u '+%Y%m%d%H%M%S')"
    log "fresh-save mode: pointing the server at throwaway save '$FRESH_SAVE_NAME'"

    cp "$SERVER_CONFIG" "$OUTPUT_DIR/sdtdserver.xml.bak"
    # Rewrite only the value of the GameName property, leaving the rest of the line
    # (whitespace alignment and the trailing comment) untouched.
    sed -i -E "s|(<property name=\"GameName\"[[:space:]]*value=\")[^\"]*(\")|\1${FRESH_SAVE_NAME}\2|" "$SERVER_CONFIG"

    grep -q "value=\"${FRESH_SAVE_NAME}\"" "$SERVER_CONFIG" \
        || die "failed to set GameName in $SERVER_CONFIG (backup at $OUTPUT_DIR/sdtdserver.xml.bak)"

    # Written only once the config edit is confirmed: 07-teardown.sh treats this file as
    # "this run created that save, it is safe to delete", so it must never name a save the
    # server was not actually pointed at.
    printf '%s' "$FRESH_SAVE_NAME" > "$OUTPUT_DIR/fresh-save-name.txt"
else
    log "reusing the profile's persistent save (${GAME_SAVE_NAME:-<unset>})"
fi

docker_server_start
# 300s is enough for a normal load of an already-generated world, but a first-ever boot
# against a brand-new WorldGenSeed (see docs/lessons-learned.md on why a fresh world is
# used per profile) can take 5+ minutes, especially with the v2.6 line's The Wasteland
# overhaul mod - observed 340s in testing.
docker_server_wait_started 480
log "server is up"
