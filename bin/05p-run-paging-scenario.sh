#!/usr/bin/env bash
# Fills the destination list past one page and walks the pages.
#
# The dialog shows DestinationsPerPage = 5 entries at a time (a constant in DialogPatches.cs,
# not a setting), and every other scenario records five traders at most - one of which is the
# one being talked to, so the list has always been four entries and one page. Paging has never
# run in a test, and the runbook said as much: seeding a longer list "needs the mod's
# internals". It does not. Recording is just opening a trader's dialog, and traders can be
# spawned, so recording seven of them is enough.
#
# What this checks, all through the shipped dialog:
#   - a full first page plus a next-page entry, and no previous-page entry on it
#   - the second page carries the rest, plus a previous-page entry
#   - the pages together are the whole list, with nothing duplicated and nothing dropped
#   - going back lands on the same first page
#   - the paging entries are localized (no raw vtt_ key on screen)
#
# Writes output/<profile>/paging-result.json.
#
# Usage: 05p-run-paging-scenario.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"
# shellcheck source=lib/testpilot-queue.sh
source "$ROOT_DIR/lib/testpilot-queue.sh"
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

# Seven destinations, so the second page is not merely the leftovers of a rounding accident:
# five on page one, and a page two that is neither empty nor full.
#
# They come in two groups, and both parts of that matter, because two traders standing near
# each other are *one* destination:
#
#   VisitedTraderStore.GetKey -> "{npcID}:{areaX}:{areaZ}", where areaX/areaZ come from the
#   trader's traderArea when it has one.
#
# Spawned traders near each other end up sharing an area, so seven copies of one prefab six
# metres apart recorded a single destination - the data file showed one key, AreaX=478, while
# the stored position was 472. What distinguishes them inside an area is the npcID, and what
# distinguishes the same npcID is being somewhere else entirely. So: four different traders
# here, then the player moves, then three more.
GROUP_A_PREFABS=(npcTraderBob npcTraderRekt npcTraderJen npcTraderHugh)
GROUP_B_PREFABS=(npcTraderJoel npcTraderBob npcTraderRekt)
TRADER_COUNT=$(( ${#GROUP_A_PREFABS[@]} + ${#GROUP_B_PREFABS[@]} ))
# Far enough to be a different trader area, close enough to stay quick.
GROUP_DISTANCE=400
DESTINATIONS_PER_PAGE=5
TRAVEL_RESPONSE_ID="vtt_open"
NEXT_ID="vtt_destination_page_next"
PREVIOUS_ID="vtt_destination_page_previous"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/paging-result.json"
rm -f "$RESULT_FILE"
REMOTE_SHOT_DIR="${OMEN_SCRATCH_DIR}\\screenshots"
LOCAL_SHOT_DIR="$OUTPUT_DIR/screenshots/paging"
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

take_screenshot() {
    local name="$1" result ok
    result="$(submit_and_check "testpilot screenshot ${REMOTE_SHOT_DIR}\\${name}")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "screenshot '$name' failed: $(printf '%s' "$result" | jq -r '.output')"
    wait_for_omen_file "${REMOTE_SHOT_DIR}\\${name}.jpg" 30 || die "screenshot '$name' never appeared"
    SHOT_NAMES+=("$name")
    log "captured screenshot: ${name}.jpg"
}

# Only the destinations, in the order the dialog offered them - the paging entries and any
# other response the dialog carries are not part of the list being paged.
destination_ids() {
    printf '%s' "$1" | jq -c "[.entries[].id
        | select(. != null)
        | select(startswith(\"vtt_destination_\")
                 and . != \"${NEXT_ID}\"
                 and . != \"${PREVIOUS_ID}\")]"
}

has_entry() {
    printf '%s' "$1" | jq -e --arg id "$2" '[.entries[].id] | any(. == $id)' >/dev/null 2>&1
}

entry_text() {
    printf '%s' "$1" | jq -r --arg id "$2" '[.entries[] | select(.id == $id) | .text] | first // ""'
}

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

spawn_trader() {
    local prefab="$1" x="$2" y="$3" z="$4" id
    id="$(world_spawn_entity "$prefab" "spawnentityat ${prefab} ${x} ${y} ${z}")" \
        || die "${prefab} did not appear in the entity list after spawning at (${x}, ${z})"
    printf '%s' "$id"
}

record_trader() {
    local id="$1" label="$2" pos
    pos="$(world_le | grep -oP "id=${id}\], pos=\(\K[^)]+" | head -1 || true)"
    log "  ${label}: id=${id} at (${pos})"
    tp_dialog open "$id" >/dev/null
    tp_dialog close >/dev/null
}

TRADER_IDS=()
log "group A: recording ${#GROUP_A_PREFABS[@]} different traders here"
for prefab in "${GROUP_A_PREFABS[@]}"; do
    id="$(spawn_trader "$prefab" "$PX" "$PY_" "$PZ")"
    TRADER_IDS+=("$id")
    record_trader "$id" "$prefab"
done

# Whole numbers: teleportplayer rejects anything else outright ("x argument is not a valid
# integer") and then quietly does nothing.
TARGET_X="$(awk -v x="$PX" -v d="$GROUP_DISTANCE" 'BEGIN { printf "%d", (x > 0) ? x - d : x + d }')"
TARGET_Z="$(awk -v z="$PZ" 'BEGIN { printf "%d", z }')"
log "moving the player ${GROUP_DISTANCE}m to (${TARGET_X}, ${TARGET_Z}) so the next group is a different place"
world_console "teleportplayer ${PLAYER_ID} ${TARGET_X} -1 ${TARGET_Z}" "" 15 >/dev/null

MOVED=0
for _ in $(seq 1 30); do
    sleep 4
    NOW="$(world_le | grep -P '\[type=EntityPlayer(Local)?, name=' | head -1 | grep -oP 'pos=\(\K[^)]+' || true)"
    [ -n "$NOW" ] || continue
    NOW_X="$(printf '%s' "$NOW" | cut -d, -f1 | tr -d ' ')"
    if awk -v a="$NOW_X" -v b="$TARGET_X" 'BEGIN { exit !((a - b < 20) && (b - a < 20)) }'; then
        MOVED=1
        break
    fi
done
[ "$MOVED" = "1" ] || die "the player never arrived at (${TARGET_X}, ${TARGET_Z}); the second group would share the first group's area"

PLAYER_NOW="$(world_le | grep -P '\[type=EntityPlayer(Local)?, name=' | head -1 | grep -oP 'pos=\(\K[^)]+')"
BX="$(printf '%s' "$PLAYER_NOW" | cut -d, -f1 | tr -d ' ')"
BY="$(printf '%s' "$PLAYER_NOW" | cut -d, -f2 | tr -d ' ')"
BZ="$(printf '%s' "$PLAYER_NOW" | cut -d, -f3 | tr -d ' ')"

log "group B: recording ${#GROUP_B_PREFABS[@]} more traders at (${BX}, ${BZ})"
for prefab in "${GROUP_B_PREFABS[@]}"; do
    id="$(spawn_trader "$prefab" "$BX" "$BY" "$BZ")"
    TRADER_IDS+=("$id")
    record_trader "$id" "$prefab"
done

log "recorded traders: ${TRADER_IDS[*]}"

# Talk to the first one. It is filtered out of its own list, so the list under test holds the
# other six - two pages of five and one.
# Talk to one the player is actually standing next to - the group A traders are 400m away
# now, and the client cannot open a dialog with an entity that far off.
TALKING_TO="${TRADER_IDS[-1]}"
log "opening the destination list from trader ${TALKING_TO}"
tp_dialog open "$TALKING_TO" >/dev/null
tp_dialog select "$TRAVEL_RESPONSE_ID" >/dev/null

# Every page is walked, rather than assuming there are exactly two of them. The seven traders
# this scenario records are the *minimum*: run inside run-release-verification.sh the earlier
# stages have already recorded their own, and a check written around "six destinations, five
# then one" failed there for no better reason than the world having more in it. What is
# actually being tested - full pages, a last page, nothing duplicated or dropped - does not
# depend on the total.
PAGES_JSON="[]"
CONTROLS_JSON="[]"
NEXT_TEXT=""
PREVIOUS_TEXT=""
PAGE_INDEX=0
MAX_PAGES=12
while : ; do
    PAGE_INDEX=$((PAGE_INDEX + 1))
    [ "$PAGE_INDEX" -le "$MAX_PAGES" ] || die "more than ${MAX_PAGES} pages; something is not advancing"

    DUMP="$(tp_dialog_dump)"
    [ "$PAGE_INDEX" -le 3 ] && take_screenshot "0${PAGE_INDEX}-page-${PAGE_INDEX}"
    IDS="$(destination_ids "$DUMP")"
    HAS_NEXT=false; has_entry "$DUMP" "$NEXT_ID" && HAS_NEXT=true
    HAS_PREVIOUS=false; has_entry "$DUMP" "$PREVIOUS_ID" && HAS_PREVIOUS=true
    [ -n "$NEXT_TEXT" ] || NEXT_TEXT="$(entry_text "$DUMP" "$NEXT_ID")"
    [ -n "$PREVIOUS_TEXT" ] || PREVIOUS_TEXT="$(entry_text "$DUMP" "$PREVIOUS_ID")"
    log "page ${PAGE_INDEX}: $(printf '%s' "$IDS" | jq 'length') destinations, next=${HAS_NEXT} previous=${HAS_PREVIOUS}"

    PAGES_JSON="$(jq -n --argjson acc "$PAGES_JSON" --argjson ids "$IDS" '$acc + [$ids]')"
    CONTROLS_JSON="$(jq -n --argjson acc "$CONTROLS_JSON" --argjson next "$HAS_NEXT" \
        --argjson previous "$HAS_PREVIOUS" '$acc + [{has_next: $next, has_previous: $previous}]')"

    [ "$HAS_NEXT" = "true" ] || break
    tp_dialog select "$NEXT_ID" >/dev/null
done

[ "$PAGE_INDEX" -ge 2 ] \
    || die "the whole list fitted on one page ($(printf '%s' "$PAGES_JSON" | jq '[.[]|length]|add') destinations), so there was no paging to test"

log "going back one page"
tp_dialog select "$PREVIOUS_ID" >/dev/null
BACK="$(tp_dialog_dump)"
take_screenshot "99-back-one-page"
BACK_IDS="$(destination_ids "$BACK")"

submit_and_check "testpilot dialog close" >/dev/null 2>&1 || true

log "collecting screenshots to $LOCAL_SHOT_DIR..."
for name in "${SHOT_NAMES[@]}"; do
    copy_from_omen "${REMOTE_SHOT_DIR}\\${name}.jpg" "$LOCAL_SHOT_DIR/${name}.jpg" \
        || die "failed to collect screenshot ${name}.jpg"
done

SHOTS_JSON="$(printf '%s\n' "${SHOT_NAMES[@]}" | jq -R . | jq -s 'map(. + ".jpg")')"

jq -n \
    --arg mode "${TESTPILOT_MODE:-connect}" \
    --arg next_text "$NEXT_TEXT" \
    --arg previous_text "$PREVIOUS_TEXT" \
    --arg screenshot_dir "${LOCAL_SHOT_DIR#"$ROOT_DIR/"}" \
    --argjson traders_recorded "$TRADER_COUNT" \
    --argjson per_page "$DESTINATIONS_PER_PAGE" \
    --argjson pages "$PAGES_JSON" \
    --argjson controls "$CONTROLS_JSON" \
    --argjson back_one_page "$BACK_IDS" \
    --argjson screenshots "$SHOTS_JSON" \
    '{mode: $mode,
      traders_recorded: $traders_recorded,
      per_page: $per_page,
      pages: $pages,
      page_controls: $controls,
      back_one_page: $back_one_page,
      labels: {next: $next_text, previous: $previous_text},
      screenshots: $screenshots,
      screenshot_dir: $screenshot_dir}' > "$RESULT_FILE"

log "paging scenario complete, results written to $RESULT_FILE"
