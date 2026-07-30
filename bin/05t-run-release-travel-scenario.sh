#!/usr/bin/env bash
# Travels between two traders on the packaged Release build, through the dialog, the way a
# player does - and checks the server agrees it happened.
#
# 05r covers what the shipped build *renders*. This covers what it *does*: recording a
# visit, resolving a destination key, and running the whole travel path end to end. Those
# are the parts a release can carry a code change in (the mod's store, key canonicalization,
# travel readiness and cost logic all moved into VisitedTraderTeleport.Core between 0.7.9
# and 0.7.10), and none of them are reachable from a dialog screenshot.
#
# Everything goes through `testpilot dialog`, so it works against a build with no test
# harness in it - which is the point. `vtttest teleport` would be the Debug-only shortcut.
#
# Safety: both traders are spawned at the player's own position, so the destination is
# terrain the player is already standing on. Travelling to a far-away recorded destination
# is what killed the player in an earlier version of the roundtrip scenario - see
# docs/lessons-learned.md.
#
# Writes output/<profile>/release-travel-result.json.
#
# Usage: 05t-run-release-travel-scenario.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"
# shellcheck source=lib/testpilot-queue.sh
source "$ROOT_DIR/lib/testpilot-queue.sh"
# shellcheck source=lib/docker-server.sh
source "$ROOT_DIR/lib/docker-server.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq grep find
require_var OMEN_SCRATCH_DIR SERVER_SAVES_DIR GAME_SAVE_NAME

TRADER_PREFABS=(npcTraderBob npcTraderJen)
TRAVEL_RESPONSE_ID="vtt_open"
CONFIRM_YES_ID="vtt_confirm_yes"

# The mod hands the trip to the server, which prepares the destination area before moving
# anyone. 05-run-scenario.sh settled on 10s for the same window; 20s here because this also
# waits out the arrival transition before reading the player back.
TRAVEL_SETTLE_SECONDS=20

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/release-travel-result.json"
REMOTE_SHOT_DIR="${OMEN_SCRATCH_DIR}\\screenshots"
LOCAL_SHOT_DIR="$OUTPUT_DIR/screenshots/travel"
SHOT_NAMES=()

tp_cmd() {
    local result ok
    result="$(submit_and_check "testpilot dialog $*")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "testpilot dialog $* failed: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$result"
}

tp_dump() {
    local result dump
    result="$(tp_cmd dump)"
    dump="$(printf '%s' "$result" | jq -r '.output' | grep -oP '^TESTPILOT_DIALOG_DUMP \K.*' | tail -1 || true)"
    [ -n "$dump" ] || die "no TESTPILOT_DIALOG_DUMP marker in: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$dump"
}

# Like tp_cmd/tp_dump but never fatal: after the travel response is activated the mod closes
# the dialog, so "no dialog is open" is the expected answer rather than a failure.
tp_try() {
    submit_and_check "testpilot dialog $*" >/dev/null 2>&1 || true
}

tp_dump_optional() {
    local result dump
    result="$(submit_and_check "testpilot dialog dump" 2>/dev/null || true)"
    dump="$(printf '%s' "$result" | jq -r '.output? // ""' 2>/dev/null | grep -oP '^TESTPILOT_DIALOG_DUMP \K.*' | tail -1 || true)"
    printf '%s' "$dump"
}

take_screenshot() {
    local name="$1" result ok
    result="$(submit_and_check "testpilot screenshot ${REMOTE_SHOT_DIR}\\${name}")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "screenshot '$name' failed: $(printf '%s' "$result" | jq -r '.output')"
    wait_for_omen_file "${REMOTE_SHOT_DIR}\\${name}.jpg" 30 \
        || die "screenshot '$name' never appeared"
    SHOT_NAMES+=("$name")
    log "captured screenshot: ${name}.jpg"
}

player_state() {
    local le_line pos dead health
    le_line="$(submit_and_check "le" | jq -r '.output' | grep -F 'EntityPlayerLocal' | head -1 || true)"
    [ -n "$le_line" ] || die "could not find EntityPlayerLocal in 'le' output"
    pos="$(printf '%s' "$le_line" | grep -oP 'pos=\(\K[^)]+' || true)"
    dead="$(printf '%s' "$le_line" | grep -oP 'dead=\K[A-Za-z]+' || true)"
    health="$(printf '%s' "$le_line" | grep -oP 'health=\K-?[0-9]+' || true)"
    if [ -z "$pos" ] || [ -z "$dead" ] || [ -z "$health" ]; then
        die "could not parse the player's state out of 'le': $le_line"
    fi
    jq -n --arg pos "$pos" --arg dead "$dead" --argjson health "$health" \
        '{position: ($pos | split(", ") | map(tonumber)),
          dead: ($dead | ascii_downcase == "true"),
          health: $health}'
}

log "clearing screenshot directory..."
run_on_omen_cmd "Remove-Item '${REMOTE_SHOT_DIR}' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '${REMOTE_SHOT_DIR}' | Out-Null"
rm -rf "$LOCAL_SHOT_DIR"
mkdir -p "$LOCAL_SHOT_DIR"

log "step: le (locating the player)"
LE_OUTPUT="$(submit_and_check "le" | jq -r '.output')"
PLAYER_ID="$(printf '%s' "$LE_OUTPUT" | grep -oP 'EntityPlayerLocal.*?id=\K[0-9]+' | head -1 || true)"
[ -n "$PLAYER_ID" ] || die "could not find the local player's entity id in 'le' output"

log "spawning ${TRADER_PREFABS[*]} next to player id=$PLAYER_ID"
for prefab in "${TRADER_PREFABS[@]}"; do
    submit_and_check "se ${PLAYER_ID} ${prefab} 1" >/dev/null
done

LE_OUTPUT="$(submit_and_check "le" | jq -r '.output')"
TRADER_IDS=()
for prefab in "${TRADER_PREFABS[@]}"; do
    id="$(printf '%s' "$LE_OUTPUT" | grep -oP "name=${prefab}, id=\K[0-9]+" | head -1 || true)"
    [ -n "$id" ] || die "could not find or spawn ${prefab}"
    TRADER_IDS+=("$id")
done
log "trader entity ids: ${TRADER_IDS[*]}"

log "recording a visit for each trader by opening its dialog"
for id in "${TRADER_IDS[@]}"; do
    tp_cmd open "$id" >/dev/null
    tp_cmd close >/dev/null
done

PLAYER_BEFORE="$(player_state)"
log "player before travel: $(printf '%s' "$PLAYER_BEFORE" | jq -c .)"

# Everything the server logs from here on belongs to this trip, so remember where the log
# currently ends and only read past that afterwards.
SERVER_LOG="$(docker_server_latest_log)"
[ -n "$SERVER_LOG" ] || die "could not find the server's output log"
LOG_LINES_BEFORE="$(wc -l < "$SERVER_LOG")"
log "server log: $SERVER_LOG (${LOG_LINES_BEFORE} lines so far)"

log "step: opening ${TRADER_PREFABS[0]}'s dialog and the destination list"
tp_cmd open "${TRADER_IDS[0]}" >/dev/null
tp_cmd select "$TRAVEL_RESPONSE_ID" >/dev/null
DUMP_DESTINATIONS="$(tp_dump)"
take_screenshot "01-destinations"

# The trader being talked to is filtered out of its own list, so the one entry left is the
# other trader - the destination this travels to.
DESTINATION_ID="$(printf '%s' "$DUMP_DESTINATIONS" | jq -r '
    [.entries[].id
     | select(. != null)
     | select(startswith("vtt_destination_")
              and . != "vtt_destination_page_next"
              and . != "vtt_destination_page_previous")] | first // empty')"
[ -n "$DESTINATION_ID" ] || die "no destination to travel to in: $DUMP_DESTINATIONS"
DESTINATION_TEXT="$(printf '%s' "$DUMP_DESTINATIONS" | jq -r --arg id "$DESTINATION_ID" '.entries[] | select(.id == $id) | .text')"
log "travelling to ${DESTINATION_ID} (${DESTINATION_TEXT})"

tp_cmd select "$DESTINATION_ID" >/dev/null

# Confirmation is configurable (Confirmation mode= in VisitedTraderTeleport.xml; the shipped
# default is whenCost, and travel cost ships disabled, so normally no confirmation appears).
# Handle both so this does not depend on the installed config.
CONFIRMED="not required"
DUMP_AFTER_SELECT="$(tp_dump_optional)"
if printf '%s' "$DUMP_AFTER_SELECT" | jq -e --arg id "$CONFIRM_YES_ID" '[.entries[].id] | any(. == $id)' >/dev/null 2>&1; then
    take_screenshot "02-confirm"
    log "confirmation screen shown; confirming"
    tp_cmd select "$CONFIRM_YES_ID" >/dev/null
    CONFIRMED="confirmed"
fi

log "waiting ${TRAVEL_SETTLE_SECONDS}s for the destination preparation and arrival transition..."
sleep "$TRAVEL_SETTLE_SECONDS"
take_screenshot "03-after-travel"

PLAYER_AFTER="$(player_state)"
log "player after travel: $(printf '%s' "$PLAYER_AFTER" | jq -c .)"

# The decisive evidence, and it comes from the server rather than from the thing under test
# reporting on itself: VisitedTraderTeleportService logs "Teleported ..." on success and
# "Teleport failed: ..." otherwise.
NEW_LOG="$(tail -n "+$((LOG_LINES_BEFORE + 1))" "$SERVER_LOG")"
TELEPORTED_COUNT="$(printf '%s\n' "$NEW_LOG" | grep -c '\[VisitedTraderTeleport\] Teleported' || true)"
TELEPORT_FAILED_COUNT="$(printf '%s\n' "$NEW_LOG" | grep -c '\[VisitedTraderTeleport\] Teleport failed' || true)"
MOD_EXCEPTIONS="$(printf '%s\n' "$NEW_LOG" | grep -c 'Exception' || true)"
log "server log since travel: Teleported=${TELEPORTED_COUNT} failed=${TELEPORT_FAILED_COUNT} exceptions=${MOD_EXCEPTIONS}"

tp_try close

log "collecting screenshots to $LOCAL_SHOT_DIR..."
for name in "${SHOT_NAMES[@]}"; do
    copy_from_omen "${REMOTE_SHOT_DIR}\\${name}.jpg" "$LOCAL_SHOT_DIR/${name}.jpg" \
        || die "failed to collect screenshot ${name}.jpg"
done

# The visit records the trip depended on have to still be in the server's save, matched on
# the exact save slot rather than "newest file" - see 03-deploy-mods.sh on why.
SAVE_NAME="$(effective_game_save_name "$OUTPUT_DIR")"
DATA_FILE="$(find "$SERVER_SAVES_DIR" -path "*/${SAVE_NAME}/VisitedTraderTeleportData.json" 2>/dev/null | head -1)"
[ -n "$DATA_FILE" ] || die "no VisitedTraderTeleportData.json found under $SERVER_SAVES_DIR for save name '$SAVE_NAME'"
RECORDED_KEYS="$(jq '[.Traders | keys[]]' "$DATA_FILE")"
# At least the traders this scenario recorded, and possibly more: within one run of
# run-release-verification.sh the dialog walkthrough (05r) has already recorded its own
# five, and visit history is only reset by 03-deploy-mods.sh at the start of the run. So
# assert a floor, not an exact count.
PLAYER_VISIT_COUNT="$(jq '[.VisitsByPlayer[]? | length] | add // 0' "$DATA_FILE")"
log "server-side recorded keys: $(printf '%s' "$RECORDED_KEYS" | jq -c .)"
log "server-side visits recorded for players: ${PLAYER_VISIT_COUNT}"

SHOTS_JSON="$(printf '%s\n' "${SHOT_NAMES[@]}" | jq -R . | jq -s 'map(. + ".jpg")')"

jq -n \
    --arg destination_id "$DESTINATION_ID" \
    --arg destination_text "$DESTINATION_TEXT" \
    --arg confirmation "$CONFIRMED" \
    --arg data_file "$DATA_FILE" \
    --arg screenshot_dir "${LOCAL_SHOT_DIR#"$ROOT_DIR/"}" \
    --argjson teleported "${TELEPORTED_COUNT:-0}" \
    --argjson teleport_failed "${TELEPORT_FAILED_COUNT:-0}" \
    --argjson server_exceptions "${MOD_EXCEPTIONS:-0}" \
    --argjson recorded_keys "$RECORDED_KEYS" \
    --argjson minimum_recorded_keys "${#TRADER_PREFABS[@]}" \
    --argjson player_visits "${PLAYER_VISIT_COUNT:-0}" \
    --argjson player_before "$PLAYER_BEFORE" \
    --argjson player_after "$PLAYER_AFTER" \
    --argjson screenshots "$SHOTS_JSON" \
    '{
        destination_id: $destination_id,
        destination_text: $destination_text,
        confirmation: $confirmation,
        data_file: $data_file,
        screenshot_dir: $screenshot_dir,
        server: {teleported: $teleported, teleport_failed: $teleport_failed, exceptions: $server_exceptions},
        recorded_keys: $recorded_keys,
        minimum_recorded_keys: $minimum_recorded_keys,
        player_visits: $player_visits,
        player: {before: $player_before, after: $player_after},
        screenshots: $screenshots
    }' > "$RESULT_FILE"

log "release travel scenario complete, results written to $RESULT_FILE"
