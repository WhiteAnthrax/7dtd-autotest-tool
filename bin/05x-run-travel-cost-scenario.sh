#!/usr/bin/env bash
# Travels with the cost setting switched on, and counts what it took.
#
# The cost calculation is unit-tested (TravelCostCalculator). What is not tested anywhere is
# the layer that reaches into the player's inventory and removes the items -
# GamePlayerInventory, which talks to the game directly and so cannot be unit-tested at all.
# TravelCostService carries explicit "removed too few" and "removed too many" branches, which
# says plainly enough that the author thought this could go wrong.
#
# Turning the cost on also turns on a second untested path: the shipped Confirmation mode is
# `whenCost`, so a confirmation screen only ever appears when a trip costs something. Every
# other scenario reports "confirmation: not required".
#
# Both directions are checked, in this order so no config reload is needed in between:
#
#   1. broke   - the player has none of the item; travel must be refused and nothing taken
#   2. paying  - the player is given some; the trip happens and takes exactly the cost
#
# 03c-configure-travel-cost.sh must have run before the client started.
#
# Writes output/<profile>/travel-cost-result.json.
#
# Usage: 05x-run-travel-cost-scenario.sh <profile>
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
require_cmd jq grep
require_var OMEN_SCRATCH_DIR

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/travel-cost-result.json"
rm -f "$RESULT_FILE"

[ -f "$OUTPUT_DIR/travel-cost-expected.txt" ] \
    || die "no $OUTPUT_DIR/travel-cost-expected.txt - 03c-configure-travel-cost.sh has to run before the client starts"
EXPECTED_COST="$(cat "$OUTPUT_DIR/travel-cost-expected.txt")"
COST_ITEM="$(cat "$OUTPUT_DIR/travel-cost-item.txt")"
# Enough for the trip and obviously more than it, so "took everything" is distinguishable
# from "took the right amount".
STARTING_ITEMS=$((EXPECTED_COST * 3))

TRADER_A_PREFAB="npcTraderBob"
TRADER_B_PREFAB="npcTraderJen"
TRAVEL_RESPONSE_ID="vtt_open"
CONFIRM_YES_ID="vtt_confirm_yes"
CONFIRM_COST_ID="vtt_confirm_costline"
REMOTE_SHOT_DIR="${OMEN_SCRATCH_DIR}\\screenshots"
LOCAL_SHOT_DIR="$OUTPUT_DIR/screenshots/cost"
SHOT_NAMES=()

tp_dialog() {
    local result ok
    result="$(submit_and_check "testpilot dialog $*")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "testpilot dialog $* failed: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$result"
}

tp_dump_optional() {
    local result
    result="$(submit_and_check "testpilot dialog dump" 2>/dev/null || true)"
    printf '%s' "$result" | jq -r '.output? // ""' 2>/dev/null \
        | grep -oP '^TESTPILOT_DIALOG_DUMP \K.*' | tail -1 || true
}

tp_dialog_dump() {
    local dump
    dump="$(tp_dump_optional)"
    [ -n "$dump" ] || die "no dialog is open"
    printf '%s' "$dump"
}

take_screenshot() {
    local name="$1" result ok
    result="$(submit_and_check "testpilot screenshot ${REMOTE_SHOT_DIR}\\${name}")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "screenshot '$name' failed: $(printf '%s' "$result" | jq -r '.output')"
    wait_for_omen_file "${REMOTE_SHOT_DIR}\\${name}.jpg" 30 || die "screenshot '$name' never appeared"
    SHOT_NAMES+=("$name")
}

# Client-side, unlike the companion markers. A player's inventory is not a piece of world
# state that lives wherever the world lives: the real one belongs to the client, and the
# server's copy of a remote player would not take the items at all - the first attempt got
# "could not fit 21 x casinoCoin in the backpack" from a server-side bag. It is also the right
# place to measure from, because the mod charges a remote player through the client
# ("Consumed local travel cost for ..."), and what the player sees is what matters.
item_count() {
    local out total
    out="$(submit_and_check "testpilot inventory count ${COST_ITEM}" | jq -r '.output')"
    total="$(printf '%s' "$out" | grep -oP 'TESTPILOT_INVENTORY \K\{.*' | tail -1 | jq -r '.total' 2>/dev/null || true)"
    [ -n "$total" ] || die "could not read the ${COST_ITEM} count: $out"
    printf '%s' "$total"
}

give_items() {
    local out
    out="$(submit_and_check "testpilot inventory give ${COST_ITEM} $1" | jq -r '.output')"
    printf '%s' "$out" | grep -q '"action":"inventory.give","ok":true' \
        || die "could not give the player ${COST_ITEM}: $out"
}

marker_count() { world_log_grep_count "VisitedTraderTeleport\] $1"; }
# Charging happens on the client even when a server owns the world, so its log is where the
# consumption lines and the over/under-removal warnings appear. Counting them server-side
# found nothing and read as "the code never ran" - while the inventory had visibly changed.
client_marker_count() { client_log_grep_count "VisitedTraderTeleport\] $1"; }

log "clearing screenshot directory..."
run_on_omen_cmd "if (Test-Path '${REMOTE_SHOT_DIR}') { Remove-Item '${REMOTE_SHOT_DIR}' -Recurse -Force }; New-Item -ItemType Directory -Force -Path '${REMOTE_SHOT_DIR}' | Out-Null"
rm -rf "$LOCAL_SHOT_DIR"
mkdir -p "$LOCAL_SHOT_DIR"

LE_START="$(world_le)"
PLAYER_ID="$(world_player_id "$LE_START")"
[ -n "$PLAYER_ID" ] || die "could not find the player's entity id in 'le' output"
PLAYER_LINE="$(printf '%s' "$LE_START" | grep -P '\[type=EntityPlayer(Local)?, name=' | head -1)"
PLAYER_POS="$(printf '%s' "$PLAYER_LINE" | grep -oP 'pos=\(\K[^)]+')"
PX="$(printf '%s' "$PLAYER_POS" | cut -d, -f1 | tr -d ' ')"
PY_="$(printf '%s' "$PLAYER_POS" | cut -d, -f2 | tr -d ' ')"
PZ="$(printf '%s' "$PLAYER_POS" | cut -d, -f3 | tr -d ' ')"

log "spawning two traders at the player and recording both"
TRADER_A_ID="$(world_spawn_entity "$TRADER_A_PREFAB" "spawnentityat ${TRADER_A_PREFAB} ${PX} ${PY_} ${PZ}")" \
    || die "could not spawn ${TRADER_A_PREFAB}"
TRADER_B_ID="$(world_spawn_entity "$TRADER_B_PREFAB" "spawnentityat ${TRADER_B_PREFAB} ${PX} ${PY_} ${PZ}")" \
    || die "could not spawn ${TRADER_B_PREFAB}"
for id in "$TRADER_A_ID" "$TRADER_B_ID"; do
    tp_dialog open "$id" >/dev/null
    tp_dialog close >/dev/null
done

BROKE_COUNT_BEFORE="$(item_count)"
log "the player is carrying ${BROKE_COUNT_BEFORE} x ${COST_ITEM}; a trip costs ${EXPECTED_COST}"
[ "$BROKE_COUNT_BEFORE" -lt "$EXPECTED_COST" ] \
    || die "this save already has ${BROKE_COUNT_BEFORE} x ${COST_ITEM}, so the cannot-afford case cannot be tested"

TELEPORTED_BEFORE="$(marker_count 'Teleported')"
CONSUMED_BEFORE="$(client_marker_count 'Consumed')"

# --- 1. cannot afford ------------------------------------------------------------------
log "step 1: trying to travel with nothing to pay with"
tp_dialog open "$TRADER_A_ID" >/dev/null
tp_dialog select "$TRAVEL_RESPONSE_ID" >/dev/null
BROKE_DUMP="$(tp_dialog_dump)"
take_screenshot "01-cannot-afford-list"
BROKE_DESTINATION="$(printf '%s' "$BROKE_DUMP" | jq -r '
    [.entries[].id | select(. != null)
     | select(startswith("vtt_destination_")
              and . != "vtt_destination_page_next"
              and . != "vtt_destination_page_previous")] | first // empty')"
[ -n "$BROKE_DESTINATION" ] || die "no destination offered at all: $BROKE_DUMP"

tp_dialog select "$BROKE_DESTINATION" >/dev/null
sleep 5
BROKE_AFTER_SELECT="$(tp_dump_optional)"
BROKE_SAW_CONFIRM=false
if printf '%s' "$BROKE_AFTER_SELECT" | jq -e --arg id "$CONFIRM_YES_ID" '[.entries[].id] | any(. == $id)' >/dev/null 2>&1; then
    BROKE_SAW_CONFIRM=true
    take_screenshot "02-cannot-afford-confirm"
    log "a confirmation appeared even though the player cannot pay; confirming to see what happens"
    tp_dialog select "$CONFIRM_YES_ID" >/dev/null
    sleep 10
fi
submit_and_check "testpilot dialog close" >/dev/null 2>&1 || true
sleep 5

BROKE_TELEPORTS="$(( $(marker_count 'Teleported') - TELEPORTED_BEFORE ))"
BROKE_COUNT_AFTER="$(item_count)"
log "after the broke attempt: teleports=${BROKE_TELEPORTS} items=${BROKE_COUNT_AFTER}"

# --- 2. paying -------------------------------------------------------------------------
log "step 2: giving the player ${STARTING_ITEMS} x ${COST_ITEM} and travelling"
give_items "$STARTING_ITEMS"
PAID_COUNT_BEFORE="$(item_count)"
log "the player is now carrying ${PAID_COUNT_BEFORE} x ${COST_ITEM}"

TELEPORTED_BEFORE_PAID="$(marker_count 'Teleported')"
tp_dialog open "$TRADER_A_ID" >/dev/null
tp_dialog select "$TRAVEL_RESPONSE_ID" >/dev/null
PAID_DUMP="$(tp_dialog_dump)"
PAID_DESTINATION="$(printf '%s' "$PAID_DUMP" | jq -r '
    [.entries[].id | select(. != null)
     | select(startswith("vtt_destination_")
              and . != "vtt_destination_page_next"
              and . != "vtt_destination_page_previous")] | first // empty')"
[ -n "$PAID_DESTINATION" ] || die "no destination offered: $PAID_DUMP"
tp_dialog select "$PAID_DESTINATION" >/dev/null
sleep 3

# The confirmation is the other half of what enabling cost turns on, so what it says is
# recorded rather than just clicked through.
PAID_CONFIRM_DUMP="$(tp_dump_optional)"
PAID_SAW_CONFIRM=false
CONFIRM_COST_TEXT=""
if printf '%s' "$PAID_CONFIRM_DUMP" | jq -e --arg id "$CONFIRM_YES_ID" '[.entries[].id] | any(. == $id)' >/dev/null 2>&1; then
    PAID_SAW_CONFIRM=true
    take_screenshot "03-confirm"
    CONFIRM_COST_TEXT="$(printf '%s' "$PAID_CONFIRM_DUMP" | jq -r --arg id "$CONFIRM_COST_ID" \
        '[.entries[] | select(.id == $id) | .text] | first // ""')"
    log "confirmation shown, cost line reads '${CONFIRM_COST_TEXT}'"
    tp_dialog select "$CONFIRM_YES_ID" >/dev/null
fi

sleep 20
take_screenshot "04-after-travel"
submit_and_check "testpilot dialog close" >/dev/null 2>&1 || true

PAID_TELEPORTS="$(( $(marker_count 'Teleported') - TELEPORTED_BEFORE_PAID ))"
CONSUMED_LINES="$(( $(client_marker_count 'Consumed') - CONSUMED_BEFORE ))"
PAID_COUNT_AFTER="$(item_count)"
SPENT="$(( PAID_COUNT_BEFORE - PAID_COUNT_AFTER ))"
log "after paying: teleports=${PAID_TELEPORTS} consumed_log_lines=${CONSUMED_LINES} items ${PAID_COUNT_BEFORE} -> ${PAID_COUNT_AFTER} (spent ${SPENT}, expected ${EXPECTED_COST})"

OVER="$(client_marker_count 'cost removal over')"
UNDER="$(client_marker_count 'cost removal under')"

log "collecting screenshots to $LOCAL_SHOT_DIR..."
for name in "${SHOT_NAMES[@]}"; do
    copy_from_omen "${REMOTE_SHOT_DIR}\\${name}.jpg" "$LOCAL_SHOT_DIR/${name}.jpg" \
        || die "failed to collect screenshot ${name}.jpg"
done
SHOTS_JSON="$(printf '%s\n' "${SHOT_NAMES[@]}" | jq -R . | jq -s 'map(. + ".jpg")')"

jq -n \
    --arg mode "${TESTPILOT_MODE:-connect}" \
    --arg item "$COST_ITEM" \
    --arg confirm_cost_text "$CONFIRM_COST_TEXT" \
    --arg screenshot_dir "${LOCAL_SHOT_DIR#"$ROOT_DIR/"}" \
    --argjson expected_cost "$EXPECTED_COST" \
    --argjson broke_before "$BROKE_COUNT_BEFORE" \
    --argjson broke_after "$BROKE_COUNT_AFTER" \
    --argjson broke_teleports "$BROKE_TELEPORTS" \
    --argjson broke_saw_confirmation "$BROKE_SAW_CONFIRM" \
    --argjson paid_before "$PAID_COUNT_BEFORE" \
    --argjson paid_after "$PAID_COUNT_AFTER" \
    --argjson spent "$SPENT" \
    --argjson paid_teleports "$PAID_TELEPORTS" \
    --argjson paid_saw_confirmation "$PAID_SAW_CONFIRM" \
    --argjson consumed_log_lines "$CONSUMED_LINES" \
    --argjson over_removals "${OVER:-0}" \
    --argjson under_removals "${UNDER:-0}" \
    --argjson screenshots "$SHOTS_JSON" \
    '{mode: $mode,
      item: $item,
      expected_cost: $expected_cost,
      cannot_afford: {items_before: $broke_before,
                      items_after: $broke_after,
                      teleports: $broke_teleports,
                      saw_confirmation: $broke_saw_confirmation},
      paying: {items_before: $paid_before,
               items_after: $paid_after,
               spent: $spent,
               teleports: $paid_teleports,
               saw_confirmation: $paid_saw_confirmation,
               confirm_cost_text: $confirm_cost_text,
               consumed_log_lines: $consumed_log_lines},
      over_removals: $over_removals,
      under_removals: $under_removals,
      screenshots: $screenshots,
      screenshot_dir: $screenshot_dir}' > "$RESULT_FILE"

log "travel cost scenario complete, results written to $RESULT_FILE"
