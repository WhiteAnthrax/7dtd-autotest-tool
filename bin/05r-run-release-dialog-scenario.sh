#!/usr/bin/env bash
# Walks the trader dialog using only SdtdTestPilot's own commands, so it works against a
# mod build that contains no test harness - i.e. the packaged Release build users download.
#
# 05b-run-dialog-scenario.sh does the richer walkthrough (seeded destinations, paging in
# both directions) but needs `vtttest dialog`, which only exists in a Debug build. This one
# trades that richness for being able to run against the real artifact:
#
#   - destinations are real, recorded by opening each trader's dialog, because seeding
#     needs the mod's internals;
#   - there are five of them (the five vanilla trader prefabs, all recorded at the player's
#     own position - distinct because a destination key carries the trader's npc id), which
#     is one page exactly, so paging rows are out of scope here;
#   - what it does prove is the thing nothing else can: that the shipped binary loads its
#     Config, runs its dialog patches, and renders localized text.
#
# Writes output/<profile>/release-dialog-result.json and
# output/<profile>/screenshots/<language>/*.jpg.
#
# Usage: 05r-run-release-dialog-scenario.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"
# shellcheck source=lib/testpilot-queue.sh
source "$ROOT_DIR/lib/testpilot-queue.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq grep
require_var OMEN_SCRATCH_DIR

# The five trader prefabs the base game ships. All are spawned at the player's position:
# a destination key carries the trader's npc id, so same-place traders still record as
# distinct destinations (05-run-scenario.sh relies on the same property for two of them),
# and nothing has to teleport anywhere - the travel option is never activated here.
TRADER_PREFABS=(npcTraderBob npcTraderJen npcTraderHugh npcTraderJoel npcTraderRekt)

# The mod's own response id for "Request transport to visited trader", from its dialogs.xml.
# It is a stable id, not localized text, which is exactly why the driver keys on it.
TRAVEL_RESPONSE_ID="vtt_open"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/release-dialog-result.json"

REMOTE_SHOT_DIR="${OMEN_SCRATCH_DIR}\\screenshots"
LOCAL_SHOT_DIR=""
REQUESTED_LANGUAGE="${CLIENT_LANGUAGE:-}"
SHOT_NAMES=()

# tp_cmd <subcommand...>: runs a `testpilot dialog` subcommand, dies unless it reported ok.
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

take_screenshot() {
    local name="$1" result ok
    result="$(submit_and_check "testpilot screenshot ${REMOTE_SHOT_DIR}\\${name}")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "screenshot '$name' failed: $(printf '%s' "$result" | jq -r '.output')"
    wait_for_omen_file "${REMOTE_SHOT_DIR}\\${name}.jpg" 30 \
        || die "screenshot '$name' never appeared at ${REMOTE_SHOT_DIR}\\${name}.jpg"
    SHOT_NAMES+=("$name")
    log "captured screenshot: ${name}.jpg"
}

# Same check 05b makes, and for the same reason: a player who died mid-walkthrough respawns
# elsewhere, which re-orders the distance-sorted destination list and puts the respawn UI
# over every screenshot, while the dialog data stays perfectly correct.
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

log "step: le (locating the player)"
LE_OUTPUT="$(submit_and_check "le" | jq -r '.output')"
PLAYER_ID="$(printf '%s' "$LE_OUTPUT" | grep -oP 'EntityPlayerLocal.*?id=\K[0-9]+' | head -1 || true)"
[ -n "$PLAYER_ID" ] || die "could not find the local player's entity id in 'le' output"

log "spawning ${#TRADER_PREFABS[@]} traders next to player id=$PLAYER_ID"
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

# Opening a trader's dialog is what records the visit - the mod's own
# DialogGetFirstStatementPatch does it, so this exercises the shipped build's patch rather
# than a test-only shortcut. That is the whole point of driving it this way.
log "recording a visit for each trader by opening its dialog"
for id in "${TRADER_IDS[@]}"; do
    tp_cmd open "$id" >/dev/null
    tp_cmd close >/dev/null
done

PLAYER_BEFORE="$(player_state)"
log "player before: $(printf '%s' "$PLAYER_BEFORE" | jq -c .)"

log "step: reopening ${TRADER_PREFABS[0]} (entity ${TRADER_IDS[0]})"
tp_cmd open "${TRADER_IDS[0]}" >/dev/null
DUMP_START="$(tp_dump)"

ACTIVE_LANGUAGE="$(printf '%s' "$DUMP_START" | jq -r '.language // "unknown"')"
LOCAL_SHOT_DIR="$OUTPUT_DIR/screenshots/$ACTIVE_LANGUAGE"

log "clearing screenshot directories (language: ${ACTIVE_LANGUAGE})..."
run_on_omen_cmd "Remove-Item '${REMOTE_SHOT_DIR}' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '${REMOTE_SHOT_DIR}' | Out-Null"
rm -rf "$LOCAL_SHOT_DIR"
mkdir -p "$LOCAL_SHOT_DIR"

take_screenshot "01-dialog-start"

log "step: opening the destination list (response ${TRAVEL_RESPONSE_ID})"
tp_cmd select "$TRAVEL_RESPONSE_ID" >/dev/null
DUMP_DESTINATIONS="$(tp_dump)"
take_screenshot "02-destinations"

log "step: closing the dialog"
tp_cmd close >/dev/null

PLAYER_AFTER="$(player_state)"
log "player after: $(printf '%s' "$PLAYER_AFTER" | jq -c .)"

log "collecting screenshots to $LOCAL_SHOT_DIR..."
for name in "${SHOT_NAMES[@]}"; do
    copy_from_omen "${REMOTE_SHOT_DIR}\\${name}.jpg" "$LOCAL_SHOT_DIR/${name}.jpg" \
        || die "failed to collect screenshot ${name}.jpg"
done

SHOTS_JSON="$(printf '%s\n' "${SHOT_NAMES[@]}" | jq -R . | jq -s 'map(. + ".jpg")')"
TRADERS_JSON="$(printf '%s\n' "${TRADER_IDS[@]}" | jq -R . | jq -s .)"

jq -n \
    --arg requested_language "$REQUESTED_LANGUAGE" \
    --arg screenshot_dir "${LOCAL_SHOT_DIR#"$ROOT_DIR/"}" \
    --argjson expected_destinations "${#TRADER_PREFABS[@]}" \
    --argjson trader_entity_ids "$TRADERS_JSON" \
    --argjson start "$DUMP_START" \
    --argjson destinations "$DUMP_DESTINATIONS" \
    --argjson player_before "$PLAYER_BEFORE" \
    --argjson player_after "$PLAYER_AFTER" \
    --argjson screenshots "$SHOTS_JSON" \
    '{
        requested_language: $requested_language,
        screenshot_dir: $screenshot_dir,
        expected_destinations: $expected_destinations,
        trader_entity_ids: $trader_entity_ids,
        player: {before: $player_before, after: $player_after},
        dumps: {start: $start, destinations: $destinations},
        screenshots: $screenshots
    }' > "$RESULT_FILE"

log "release dialog scenario complete, results written to $RESULT_FILE"
