#!/usr/bin/env bash
# Forgets a destination through the trader dialog, and checks it is gone for good.
#
# Issue #58: a visit is recorded the first time a trader's dialog is opened and nothing ever
# took it back out, so a trader spawned for testing stayed on the list permanently. The fix
# adds "forget this destination" to the screen you land on after picking one.
#
# What this covers, all through the shipped dialog:
#   - the destination is offered before, and gone from the list afterwards
#   - the *save file* no longer carries the visit, so it does not come back on reload
#   - the other destinations are untouched - forgetting one must not clear the lot
#   - cancelling out of the confirmation keeps the destination
#   - visiting the trader again puts it back, which is what makes this recoverable
#
# The last one matters as much as the removal: "forget" that cannot be undone by walking back
# to the trader would be a data-loss feature rather than a tidying-up one.
#
# Writes output/<profile>/forget-result.json.
#
# Usage: 05f-run-forget-scenario.sh <profile>
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
# shellcheck source=lib/dialog-drive.sh
source "$ROOT_DIR/lib/dialog-drive.sh"

trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq grep
require_var OMEN_SCRATCH_DIR

# Three traders: one to talk to, and two destinations - so "forgetting one" can be told apart
# from "clearing the list". Different prefabs because traders standing together share a
# destination key (see docs/lessons-learned.md).
# Which of the two gets forgotten is whichever the dialog lists first, so they are named for
# their role in the setup rather than for their fate.
TALK_PREFAB="npcTraderJoel"
DESTINATION_A_PREFAB="npcTraderBob"
DESTINATION_B_PREFAB="npcTraderJen"
TRAVEL_RESPONSE_ID="vtt_open"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/forget-result.json"
rm -f "$RESULT_FILE"
REMOTE_SHOT_DIR="${OMEN_SCRATCH_DIR}\\screenshots"
LOCAL_SHOT_DIR="$OUTPUT_DIR/screenshots/forget"
SHOT_NAMES=()

take_screenshot() {
    local name="$1" result ok
    result="$(submit_and_check "testpilot screenshot ${REMOTE_SHOT_DIR}\\${name}")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "screenshot '$name' failed: $(printf '%s' "$result" | jq -r '.output')"
    wait_for_omen_file "${REMOTE_SHOT_DIR}\\${name}.jpg" 30 || die "screenshot '$name' never appeared"
    SHOT_NAMES+=("$name")
}

# The destination list as the dialog currently shows it, closing afterwards so the next
# reading starts from a fresh dialog rather than from whatever screen the last step left open.
list_destinations() {
    local dump
    submit_and_check "testpilot dialog close" >/dev/null 2>&1 || true
    tp_dialog open "$TALK_ID" >/dev/null
    tp_dialog select "$TRAVEL_RESPONSE_ID" >/dev/null
    dump="$(tp_dialog_dump)"
    printf '%s' "$dump"
}

# What the *save* holds for this player, which is the part that survives a reload. The dialog
# could be right and the file wrong - that is the bug this feature must not have.
saved_visit_count() {
    local save_name data_file
    save_name="$(effective_game_save_name "$OUTPUT_DIR")"
    data_file="$(find "$SERVER_SAVES_DIR" -path "*/${save_name}/VisitedTraderTeleportData.json" 2>/dev/null | head -1)"
    if [ -z "$data_file" ]; then
        printf '%s' "-1"
        return
    fi
    jq '[.VisitsByPlayer[]? | length] | add // 0' "$data_file"
}

log "clearing screenshot directory..."
run_on_omen_cmd "if (Test-Path '${REMOTE_SHOT_DIR}') { Remove-Item '${REMOTE_SHOT_DIR}' -Recurse -Force }; New-Item -ItemType Directory -Force -Path '${REMOTE_SHOT_DIR}' | Out-Null"
rm -rf "$LOCAL_SHOT_DIR"
mkdir -p "$LOCAL_SHOT_DIR"

LE_START="$(world_le)"
PLAYER_LINE="$(printf '%s' "$LE_START" | grep -P '\[type=EntityPlayer(Local)?, name=' | head -1)"
PLAYER_POS="$(printf '%s' "$PLAYER_LINE" | grep -oP 'pos=\(\K[^)]+')"
PX="$(printf '%s' "$PLAYER_POS" | cut -d, -f1 | tr -d ' ')"
PY_="$(printf '%s' "$PLAYER_POS" | cut -d, -f2 | tr -d ' ')"
PZ="$(printf '%s' "$PLAYER_POS" | cut -d, -f3 | tr -d ' ')"

log "spawning three traders and recording each one"
TALK_ID="$(world_spawn_entity "$TALK_PREFAB" "spawnentityat ${TALK_PREFAB} ${PX} ${PY_} ${PZ}")" \
    || die "could not spawn ${TALK_PREFAB}"
DEST_A_ID="$(world_spawn_entity "$DESTINATION_A_PREFAB" "spawnentityat ${DESTINATION_A_PREFAB} ${PX} ${PY_} ${PZ}")" \
    || die "could not spawn ${DESTINATION_A_PREFAB}"
DEST_B_ID="$(world_spawn_entity "$DESTINATION_B_PREFAB" "spawnentityat ${DESTINATION_B_PREFAB} ${PX} ${PY_} ${PZ}")" \
    || die "could not spawn ${DESTINATION_B_PREFAB}"
for id in "$TALK_ID" "$DEST_A_ID" "$DEST_B_ID"; do
    tp_dialog open "$id" >/dev/null
    tp_dialog close >/dev/null
done

BEFORE_DUMP="$(list_destinations)"
take_screenshot "01-before"
BEFORE_IDS="$(dialog_destination_ids "$BEFORE_DUMP")"
BEFORE_COUNT="$(printf '%s' "$BEFORE_IDS" | jq 'length')"
SAVED_BEFORE="$(saved_visit_count)"
log "before: ${BEFORE_COUNT} destinations offered, ${SAVED_BEFORE} visits in the save"
[ "$BEFORE_COUNT" -ge 2 ] \
    || die "need at least two destinations to tell 'forgot one' from 'cleared the list', got ${BEFORE_COUNT}: ${BEFORE_DUMP}"

TARGET_ID="$(printf '%s' "$BEFORE_IDS" | jq -r 'first')"
TARGET_TEXT="$(printf '%s' "$BEFORE_DUMP" | jq -r --arg id "$TARGET_ID" '.entries[] | select(.id == $id) | .text')"
log "will forget ${TARGET_ID} (${TARGET_TEXT})"

# --- cancelling must not remove anything ------------------------------------------------
log "step 1: opening the forget confirmation and backing out of it"
tp_dialog select "$TARGET_ID" >/dev/null
sleep 2
ACTION_DUMP="$(tp_dialog_dump)"
take_screenshot "02-action-screen"
ACTION_HAS_FORGET=false
printf '%s' "$ACTION_DUMP" | jq -e '[.entries[].id] | any(. == "vtt_forget")' >/dev/null 2>&1 && ACTION_HAS_FORGET=true
[ "$ACTION_HAS_FORGET" = "true" ] || die "the action screen has no forget entry: $ACTION_DUMP"

tp_dialog select vtt_forget >/dev/null
sleep 1
CONFIRM_DUMP="$(tp_dialog_dump)"
take_screenshot "03-forget-confirm"
FORGET_PROMPT="$(printf '%s' "$CONFIRM_DUMP" | jq -r '[.entries[] | select(.id == "vtt_forget_promptline") | .text] | first // ""')"
log "confirmation reads '${FORGET_PROMPT}'"
tp_dialog select vtt_forget_no >/dev/null
sleep 2

AFTER_CANCEL_IDS="$(dialog_destination_ids "$(list_destinations)")"
CANCEL_COUNT="$(printf '%s' "$AFTER_CANCEL_IDS" | jq 'length')"
log "after cancelling: ${CANCEL_COUNT} destinations"

# --- forgetting it ------------------------------------------------------------------------
log "step 2: forgetting ${TARGET_ID}"
dialog_forget "$TARGET_ID"

AFTER_DUMP="$(list_destinations)"
take_screenshot "04-after-forget"
AFTER_IDS="$(dialog_destination_ids "$AFTER_DUMP")"
AFTER_COUNT="$(printf '%s' "$AFTER_IDS" | jq 'length')"
SAVED_AFTER="$(saved_visit_count)"
log "after forgetting: ${AFTER_COUNT} destinations offered, ${SAVED_AFTER} visits in the save"

# --- visiting again brings it back ---------------------------------------------------------
# Both, because the forgotten one is whichever the dialog listed first.
log "step 3: visiting both traders again to see the forgotten destination come back"
submit_and_check "testpilot dialog close" >/dev/null 2>&1 || true
for id in "$DEST_A_ID" "$DEST_B_ID"; do
    tp_dialog open "$id" >/dev/null
    tp_dialog close >/dev/null
done
REVISIT_IDS="$(dialog_destination_ids "$(list_destinations)")"
REVISIT_COUNT="$(printf '%s' "$REVISIT_IDS" | jq 'length')"
take_screenshot "05-after-revisit"
log "after revisiting: ${REVISIT_COUNT} destinations"

submit_and_check "testpilot dialog close" >/dev/null 2>&1 || true

log "collecting screenshots to $LOCAL_SHOT_DIR..."
for name in "${SHOT_NAMES[@]}"; do
    copy_from_omen "${REMOTE_SHOT_DIR}\\${name}.jpg" "$LOCAL_SHOT_DIR/${name}.jpg" \
        || die "failed to collect screenshot ${name}.jpg"
done
SHOTS_JSON="$(printf '%s\n' "${SHOT_NAMES[@]}" | jq -R . | jq -s 'map(. + ".jpg")')"

jq -n \
    --arg mode "${TESTPILOT_MODE:-connect}" \
    --arg target_id "$TARGET_ID" \
    --arg target_text "$TARGET_TEXT" \
    --arg forget_prompt "$FORGET_PROMPT" \
    --arg screenshot_dir "${LOCAL_SHOT_DIR#"$ROOT_DIR/"}" \
    --argjson action_screen_offers_forget "$ACTION_HAS_FORGET" \
    --argjson before "$BEFORE_IDS" \
    --argjson after_cancel "$AFTER_CANCEL_IDS" \
    --argjson after "$AFTER_IDS" \
    --argjson after_revisit "$REVISIT_IDS" \
    --argjson saved_visits_before "$SAVED_BEFORE" \
    --argjson saved_visits_after "$SAVED_AFTER" \
    --argjson screenshots "$SHOTS_JSON" \
    '{mode: $mode,
      target: {id: $target_id, text: $target_text},
      action_screen_offers_forget: $action_screen_offers_forget,
      forget_prompt: $forget_prompt,
      destinations: {before: $before,
                     after_cancel: $after_cancel,
                     after: $after,
                     after_revisit: $after_revisit},
      saved_visits: {before: $saved_visits_before, after: $saved_visits_after},
      screenshots: $screenshots,
      screenshot_dir: $screenshot_dir}' > "$RESULT_FILE"

log "forget scenario complete, results written to $RESULT_FILE"
