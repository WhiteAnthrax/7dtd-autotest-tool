#!/usr/bin/env bash
# Travels a real distance, so the destination has to be prepared before anyone is moved.
#
# Why this exists: every other travel scenario spawns its traders at the player's own feet, so
# the destination is terrain the player is already standing on. That was deliberate - an early
# scenario travelled somewhere far, unprepared, and killed the player - but it means the trip
# is spatially a no-op, and the mod skips the whole preparation path for it:
#
#     NeedsPreparation() -> !IsDestinationReady(world, target)
#
# The server log for a 0m trip proves it: one "Teleported" line and nothing else. No
# "Preparing destination", no "Queued transport", no "Stabilized arrival". Those are exactly
# the mechanisms 0.6.20 and 0.6.21 were released to fix (freezes on repeated travel, being
# kicked mid-transition, the mesh-saturation wait), and nothing has been testing them.
#
# The shape here avoids needing to know where the world's own traders are:
#
#   1. spawn trader A at the player, record the visit through its dialog
#   2. teleport the player DISTANCE metres away, and let the world load around them
#   3. spawn trader B there, record it, and travel from B back to A
#
# The return trip is then a genuine long-distance journey to an area that is no longer loaded,
# which is what a player does. The verdict is the server's own account of it (06d).
#
# Writes output/<profile>/distance-travel-result.json.
#
# Usage: 05d-run-distance-travel-scenario.sh <profile>
#   TRAVEL_DISTANCE   metres to move away before travelling back (default 1000)
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
# shellcheck source=lib/server-console.sh
source "$ROOT_DIR/lib/server-console.sh"
# shellcheck source=lib/world-console.sh
source "$ROOT_DIR/lib/world-console.sh"

trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq grep awk
require_var OMEN_SCRATCH_DIR

# 1000m is comfortably outside anything the server keeps loaded around a player (the stock
# view distance is 12 chunks, 192m), so the destination genuinely has to be brought in. It
# also stays inside a 6144 world from any starting point once the direction is chosen below.
DISTANCE="${TRAVEL_DISTANCE:-1000}"
TRADER_A_PREFAB="npcTraderHugh"
TRADER_B_PREFAB="npcTraderJen"
TRAVEL_RESPONSE_ID="vtt_open"
CONFIRM_YES_ID="vtt_confirm_yes"
# Long trips take longer than the 0m ones: the destination has to load and the arrival is
# stabilized afterwards. The scenario waits for the server to say it finished rather than
# only sleeping, and this is the ceiling on that wait.
TRAVEL_TIMEOUT_SECONDS=120
# How close to the departure point counts as "arrived". The mod puts the player next to the
# trader, not on top of it, and the trader was spawned a step from where the player stood.
ARRIVAL_TOLERANCE_METRES=60

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/distance-travel-result.json"
rm -f "$RESULT_FILE"
REMOTE_SHOT_DIR="${OMEN_SCRATCH_DIR}\\screenshots"
LOCAL_SHOT_DIR="$OUTPUT_DIR/screenshots/distance"
SHOT_NAMES=()

tp_dialog() {
    local result ok
    result="$(submit_and_check "testpilot dialog $*")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "testpilot dialog $* failed: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$result"
}

tp_dialog_dump() {
    local result dump
    result="$(tp_dialog dump)"
    dump="$(printf '%s' "$result" | jq -r '.output' | grep -oP '^TESTPILOT_DIALOG_DUMP \K.*' | tail -1 || true)"
    [ -n "$dump" ] || die "no TESTPILOT_DIALOG_DUMP marker in: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$dump"
}

tp_dump_optional() {
    local result
    result="$(submit_and_check "testpilot dialog dump" 2>/dev/null || true)"
    printf '%s' "$result" | jq -r '.output? // ""' 2>/dev/null \
        | grep -oP '^TESTPILOT_DIALOG_DUMP \K.*' | tail -1 || true
}

take_screenshot() {
    local name="$1" result ok
    result="$(submit_and_check "testpilot screenshot ${REMOTE_SHOT_DIR}\\${name}")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "screenshot '$name' failed: $(printf '%s' "$result" | jq -r '.output')"
    wait_for_omen_file "${REMOTE_SHOT_DIR}\\${name}.jpg" 30 || die "screenshot '$name' never appeared"
    SHOT_NAMES+=("$name")
    log "captured screenshot: ${name}.jpg"
}

# Entity lookups go to whichever process owns the world - see lib/world-console.sh. Spawning
# and teleporting are server-side operations when there is a server; only the dialog is
# client-side, because that is where the UI lives.
player_line() {
    world_le | grep -P '\[type=EntityPlayer(Local)?, name=' | head -1 || true
}

player_state() {
    local line pos dead health
    line="$(player_line)"
    [ -n "$line" ] || die "could not find the player in the 'le' output"
    pos="$(printf '%s' "$line" | grep -oP 'pos=\(\K[^)]+' || true)"
    dead="$(printf '%s' "$line" | grep -oP 'dead=\K[A-Za-z]+' || true)"
    health="$(printf '%s' "$line" | grep -oP 'health=\K-?[0-9]+' || true)"
    if [ -z "$pos" ] || [ -z "$dead" ] || [ -z "$health" ]; then
        die "could not parse the player's state: $line"
    fi
    jq -n --arg pos "$pos" --arg dead "$dead" --argjson health "$health" \
        '{position: ($pos | split(", ") | map(tonumber)),
          dead: ($dead | ascii_downcase == "true"),
          health: $health}'
}

pos_field() { printf '%s' "$1" | jq -r ".position[$2]"; }

distance_2d() {
    awk -v x1="$1" -v z1="$2" -v x2="$3" -v z2="$4" \
        'BEGIN { dx = x1 - x2; dz = z1 - z2; printf "%.1f", sqrt(dx*dx + dz*dz) }'
}

# world_spawn_entity, not "the first entity with this name": worlds come with their own
# traders, and picking one of those would give a valid id for the wrong entity.
spawn_and_find() { world_spawn_entity "$1" "$2"; }

# Counts one of the mod's own log markers. Which log that is depends on the topology, so this
# goes through world_log_grep_count; the window is a before/after difference because the
# hostload side can only count the whole file.
marker_count() { world_log_grep_count "VisitedTraderTeleport\] $1"; }

log "clearing screenshot directory..."
run_on_omen_cmd "if (Test-Path '${REMOTE_SHOT_DIR}') { Remove-Item '${REMOTE_SHOT_DIR}' -Recurse -Force }; New-Item -ItemType Directory -Force -Path '${REMOTE_SHOT_DIR}' | Out-Null"
rm -rf "$LOCAL_SHOT_DIR"
mkdir -p "$LOCAL_SHOT_DIR"

LE_START="$(world_le)"
PLAYER_ID="$(world_player_id "$LE_START")"
[ -n "$PLAYER_ID" ] || die "could not find the player's entity id in 'le' output"

PLAYER_START="$(player_state)"
log "player at start: $(printf '%s' "$PLAYER_START" | jq -c .)"
[ "$(printf '%s' "$PLAYER_START" | jq -r '.dead')" = "false" ] \
    || die "the player is already dead in this save - run with --fresh-save"

START_X="$(pos_field "$PLAYER_START" 0)"
START_Y="$(pos_field "$PLAYER_START" 1)"
START_Z="$(pos_field "$PLAYER_START" 2)"

log "spawning ${TRADER_A_PREFAB} (the destination) at the player's position"
TRADER_A_ID="$(spawn_and_find "$TRADER_A_PREFAB" "spawnentityat ${TRADER_A_PREFAB} ${START_X} ${START_Y} ${START_Z}")" \
    || die "could not spawn ${TRADER_A_PREFAB}"
log "recording it by opening its dialog"
tp_dialog open "$TRADER_A_ID" >/dev/null
tp_dialog close >/dev/null

# Travel towards the middle of the map rather than blindly along +X, so a player who starts
# near the edge is not sent outside the world.
#
# Rounded to whole numbers because teleportplayer only accepts integers - it answers
# "z argument is not a valid integer" to the coordinates `le` prints, and then does nothing
# at all. Its reply is the only sign; the player simply stays put.
TARGET_X="$(awk -v x="$START_X" -v d="$DISTANCE" 'BEGIN { printf "%d", (x > 0) ? x - d : x + d }')"
TARGET_Z="$(awk -v z="$START_Z" 'BEGIN { printf "%d", z }')"
log "teleporting the player ${DISTANCE}m away to (${TARGET_X}, ${TARGET_Z})"
# y = -1 means "put them on the ground", which is what the game's own help says and what
# keeps this from dropping the player into terrain that has not loaded yet.
#
# The reply is kept rather than discarded: the first version of this threw it away, the
# teleport did nothing, and all the scenario could say was "the player never arrived" - with
# the console's own explanation already thrown on the floor.
TELEPORT_REPLY="$(world_console "teleportplayer ${PLAYER_ID} ${TARGET_X} -1 ${TARGET_Z}" "" 15 | tr -d '\r' | grep -v '^\s*$' | tail -3 || true)"
log "console said: ${TELEPORT_REPLY:-<nothing>}"
if printf '%s' "$TELEPORT_REPLY" | grep -qiE "not a valid|usage:|unknown command|error"; then
    die "the console refused the teleport: ${TELEPORT_REPLY}"
fi

log "waiting for the player to arrive and the world to load around them..."
ARRIVED=0
for attempt in $(seq 1 45); do
    sleep 4
    STATE="$(player_state 2>/dev/null || true)"
    [ -n "$STATE" ] || continue
    CUR_X="$(pos_field "$STATE" 0)"
    CUR_Z="$(pos_field "$STATE" 2)"
    OFF="$(distance_2d "$CUR_X" "$CUR_Z" "$TARGET_X" "$TARGET_Z")"
    [ $((attempt % 5)) -eq 0 ] && log "  still ${OFF}m from the target (at ${CUR_X}, ${CUR_Z})"
    if awk -v o="$OFF" 'BEGIN { exit !(o < 20) }'; then
        ARRIVED=1
        break
    fi
done
[ "$ARRIVED" = "1" ] \
    || die "the player never reached (${TARGET_X}, ${TARGET_Z}) after the teleport; console said: ${TELEPORT_REPLY:-<nothing>}"

PLAYER_AWAY="$(player_state)"
log "player after the teleport: $(printf '%s' "$PLAYER_AWAY" | jq -c .)"
[ "$(printf '%s' "$PLAYER_AWAY" | jq -r '.dead')" = "false" ] \
    || die "the player died being teleported ${DISTANCE}m away, before the trip under test even started"

AWAY_X="$(pos_field "$PLAYER_AWAY" 0)"
AWAY_Y="$(pos_field "$PLAYER_AWAY" 1)"
AWAY_Z="$(pos_field "$PLAYER_AWAY" 2)"
SEPARATION="$(distance_2d "$AWAY_X" "$AWAY_Z" "$START_X" "$START_Z")"
log "the player is now ${SEPARATION}m from where ${TRADER_A_PREFAB} was recorded"

log "spawning ${TRADER_B_PREFAB} here, to talk to"
TRADER_B_ID="$(spawn_and_find "$TRADER_B_PREFAB" "spawnentityat ${TRADER_B_PREFAB} ${AWAY_X} ${AWAY_Y} ${AWAY_Z}")" \
    || die "could not spawn ${TRADER_B_PREFAB}"
tp_dialog open "$TRADER_B_ID" >/dev/null
tp_dialog close >/dev/null

PREP_STARTED_BEFORE="$(marker_count 'Preparing destination')"
PREP_READY_BEFORE="$(marker_count 'Destination ready after preparation')"
PREP_FAILED_BEFORE="$(marker_count 'Destination was not ready')"
# "Queued transport" only ever appears in failure messages - expired, or failed to start -
# so this counts problems, not work done. "Starting queued transport" is the healthy one:
# it is logged when a prepared trip is handed on to the transport step.
QUEUE_PROBLEMS_BEFORE="$(marker_count 'Queued transport')"
QUEUE_STARTED_BEFORE="$(marker_count 'Starting queued transport')"
TELEPORTED_BEFORE="$(marker_count 'Teleported')"
FAILED_BEFORE="$(marker_count 'Teleport failed')"

take_screenshot "01-before-long-trip"

log "opening ${TRADER_B_PREFAB}'s dialog and the destination list"
tp_dialog open "$TRADER_B_ID" >/dev/null
tp_dialog select "$TRAVEL_RESPONSE_ID" >/dev/null
DUMP="$(tp_dialog_dump)"
take_screenshot "02-destinations"

# The trader being talked to is filtered out of its own list, so everything left is back at
# the departure point - the far end of the trip.
DESTINATION_ID="$(printf '%s' "$DUMP" | jq -r '
    [.entries[].id
     | select(. != null)
     | select(startswith("vtt_destination_")
              and . != "vtt_destination_page_next"
              and . != "vtt_destination_page_previous")] | first // empty')"
[ -n "$DESTINATION_ID" ] || die "no destination offered in the dialog: $DUMP"
DESTINATION_TEXT="$(printf '%s' "$DUMP" | jq -r --arg id "$DESTINATION_ID" '.entries[] | select(.id == $id) | .text')"
log "travelling to ${DESTINATION_ID} (${DESTINATION_TEXT})"

TRAVEL_STARTED_AT="$(date -u +%s)"
tp_dialog select "$DESTINATION_ID" >/dev/null

CONFIRMED="not required"
DUMP_AFTER_SELECT="$(tp_dump_optional)"
if printf '%s' "$DUMP_AFTER_SELECT" | jq -e --arg id "$CONFIRM_YES_ID" '[.entries[].id] | any(. == $id)' >/dev/null 2>&1; then
    take_screenshot "03-confirm"
    log "confirmation screen shown; confirming"
    tp_dialog select "$CONFIRM_YES_ID" >/dev/null
    CONFIRMED="confirmed"
fi

# Wait for the game to say the trip finished rather than for a fixed number of seconds: how
# long a prepared trip takes is the very thing that varies, and a sleep long enough to be safe
# would hide it. Either outcome ends the wait - success and failure are both answers.
log "waiting up to ${TRAVEL_TIMEOUT_SECONDS}s for the trip to complete..."
TRAVEL_SECONDS=0
for _ in $(seq 1 "$((TRAVEL_TIMEOUT_SECONDS / 5))"); do
    sleep 5
    if [ "$(marker_count 'Teleported')" -gt "$TELEPORTED_BEFORE" ] \
        || [ "$(marker_count 'Teleport failed')" -gt "$FAILED_BEFORE" ] \
        || [ "$(marker_count 'Destination was not ready')" -gt "$PREP_FAILED_BEFORE" ]; then
        break
    fi
done
TRAVEL_SECONDS="$(( $(date -u +%s) - TRAVEL_STARTED_AT ))"
log "the game reported the trip after ${TRAVEL_SECONDS}s"
# The arrival transition (control block, chunk visuals, stabilization) runs after the log
# line, so give it a moment before reading the player back or screenshotting.
sleep 10
take_screenshot "04-after-long-trip"

PLAYER_END="$(player_state)"
log "player after travel: $(printf '%s' "$PLAYER_END" | jq -c .)"
END_X="$(pos_field "$PLAYER_END" 0)"
END_Z="$(pos_field "$PLAYER_END" 2)"
TRAVELLED="$(distance_2d "$AWAY_X" "$AWAY_Z" "$END_X" "$END_Z")"
ARRIVAL_OFFSET="$(distance_2d "$END_X" "$END_Z" "$START_X" "$START_Z")"
log "moved ${TRAVELLED}m, ending ${ARRIVAL_OFFSET}m from where ${TRADER_A_PREFAB} was recorded"

PREP_STARTED="$(( $(marker_count 'Preparing destination') - PREP_STARTED_BEFORE ))"
PREP_READY="$(( $(marker_count 'Destination ready after preparation') - PREP_READY_BEFORE ))"
PREP_FAILED="$(( $(marker_count 'Destination was not ready') - PREP_FAILED_BEFORE ))"
QUEUE_PROBLEMS="$(( $(marker_count 'Queued transport') - QUEUE_PROBLEMS_BEFORE ))"
QUEUE_STARTED="$(( $(marker_count 'Starting queued transport') - QUEUE_STARTED_BEFORE ))"
TELEPORTED="$(( $(marker_count 'Teleported') - TELEPORTED_BEFORE ))"
TELEPORT_FAILED="$(( $(marker_count 'Teleport failed') - FAILED_BEFORE ))"
log "markers for this trip: preparing=${PREP_STARTED} ready=${PREP_READY} not_ready=${PREP_FAILED} transport_started=${QUEUE_STARTED} queue_problems=${QUEUE_PROBLEMS} teleported=${TELEPORTED} failed=${TELEPORT_FAILED}"

submit_and_check "testpilot dialog close" >/dev/null 2>&1 || true

log "collecting screenshots to $LOCAL_SHOT_DIR..."
for name in "${SHOT_NAMES[@]}"; do
    copy_from_omen "${REMOTE_SHOT_DIR}\\${name}.jpg" "$LOCAL_SHOT_DIR/${name}.jpg" \
        || die "failed to collect screenshot ${name}.jpg"
done

SHOTS_JSON="$(printf '%s\n' "${SHOT_NAMES[@]}" | jq -R . | jq -s 'map(. + ".jpg")')"

jq -n \
    --arg mode "${TESTPILOT_MODE:-connect}" \
    --arg destination_id "$DESTINATION_ID" \
    --arg destination_text "$DESTINATION_TEXT" \
    --arg confirmation "$CONFIRMED" \
    --arg screenshot_dir "${LOCAL_SHOT_DIR#"$ROOT_DIR/"}" \
    --argjson requested_distance "$DISTANCE" \
    --argjson separation_before "$SEPARATION" \
    --argjson travelled "$TRAVELLED" \
    --argjson arrival_offset "$ARRIVAL_OFFSET" \
    --argjson travel_seconds "$TRAVEL_SECONDS" \
    --argjson arrival_tolerance "$ARRIVAL_TOLERANCE_METRES" \
    --argjson preparation_started "$PREP_STARTED" \
    --argjson preparation_ready "$PREP_READY" \
    --argjson preparation_failed "$PREP_FAILED" \
    --argjson queue_problems "$QUEUE_PROBLEMS" \
    --argjson transport_started "$QUEUE_STARTED" \
    --argjson teleported "$TELEPORTED" \
    --argjson teleport_failed "$TELEPORT_FAILED" \
    --argjson player_start "$PLAYER_START" \
    --argjson player_away "$PLAYER_AWAY" \
    --argjson player_end "$PLAYER_END" \
    --argjson screenshots "$SHOTS_JSON" \
    '{mode: $mode,
      requested_distance: $requested_distance,
      separation_before: $separation_before,
      travelled: $travelled,
      arrival_offset: $arrival_offset,
      arrival_tolerance: $arrival_tolerance,
      travel_seconds: $travel_seconds,
      destination: {id: $destination_id, text: $destination_text},
      confirmation: $confirmation,
      markers: {preparation_started: $preparation_started,
                preparation_ready: $preparation_ready,
                preparation_failed: $preparation_failed,
                queue_problems: $queue_problems,
                transport_started: $transport_started,
                teleported: $teleported,
                teleport_failed: $teleport_failed},
      player: {start: $player_start, away: $player_away, end: $player_end},
      screenshots: $screenshots,
      screenshot_dir: $screenshot_dir}' > "$RESULT_FILE"

log "distance travel scenario complete, results written to $RESULT_FILE"
