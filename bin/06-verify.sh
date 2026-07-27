#!/usr/bin/env bash
# Cross-checks output/<profile>/scenario-result.json against the server-side
# VisitedTraderTeleportData.json: the recorded destination key must exist in Traders and
# be attributed to some player in VisitsByPlayer.
# Usage: 06-verify.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq find

require_var SERVER_SAVES_DIR
require_var GAME_SAVE_NAME
OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
RESULT_FILE="$OUTPUT_DIR/scenario-result.json"
[ -f "$RESULT_FILE" ] || die "missing $RESULT_FILE (run 05-run-scenario.sh first)"

# Match on GAME_SAVE_NAME, not "newest file under SERVER_SAVES_DIR" - see the comment in
# 03-deploy-mods.sh for why the latter picks up unrelated worlds on this shared machine.
DATA_FILE="$(find "$SERVER_SAVES_DIR" -path "*/${GAME_SAVE_NAME}/VisitedTraderTeleportData.json" 2>/dev/null | head -1)"
[ -n "$DATA_FILE" ] || die "no VisitedTraderTeleportData.json found under $SERVER_SAVES_DIR for save name '$GAME_SAVE_NAME'"
log "using server-side data file: $DATA_FILE"

RECORD_KEY="$(jq -r '.record_reported_key' "$RESULT_FILE")"

KEY_IN_TRADERS="$(jq --arg k "$RECORD_KEY" '.Traders | has($k)' "$DATA_FILE")"
KEY_VISITED_BY_SOMEONE="$(jq --arg k "$RECORD_KEY" '[.VisitsByPlayer[] | any(. == $k)] | any' "$DATA_FILE")"

VERIFY_OK=false
if [ "$KEY_IN_TRADERS" = "true" ] && [ "$KEY_VISITED_BY_SOMEONE" = "true" ]; then
    VERIFY_OK=true
fi

jq -n \
    --arg data_file "$DATA_FILE" \
    --arg record_key "$RECORD_KEY" \
    --argjson key_in_traders "$KEY_IN_TRADERS" \
    --argjson key_visited "$KEY_VISITED_BY_SOMEONE" \
    --argjson ok "$VERIFY_OK" \
    '{data_file: $data_file, record_key: $record_key, key_in_traders: $key_in_traders, key_visited_by_someone: $key_visited, ok: $ok}' \
    > "$OUTPUT_DIR/verify-result.json"

if [ "$VERIFY_OK" = "true" ]; then
    log "verification passed: '$RECORD_KEY' is present in $DATA_FILE"
    exit 0
else
    log "verification FAILED: '$RECORD_KEY' not found as expected in $DATA_FILE (key_in_traders=$KEY_IN_TRADERS, key_visited=$KEY_VISITED_BY_SOMEONE)"
    exit 1
fi
