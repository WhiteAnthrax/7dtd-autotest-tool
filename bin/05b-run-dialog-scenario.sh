#!/usr/bin/env bash
# Walks the real trader dialog UI on the client and captures what it renders:
#   dialog open -> screenshot -> seed 7 destinations -> open the destination list ->
#   screenshot page 1 -> next page -> screenshot page 2 -> previous page -> screenshot ->
#   close.
#
# This is the part of the mod the roundtrip scenario (05) never touches: 05 calls the
# service layer directly (VisitedTraderStore.Record / DialogActionVisitedTraderTeleport),
# so nothing in DialogPatches.cs - paging, the response text, the status header, the XUi
# binding - runs at all. Everything here goes through the game's own dialog window group,
# so the Harmony patches and the localization lookups run exactly as they do for a player.
#
# Writes output/<profile>/dialog-result.json (asserted by 06-verify.sh) and
# output/<profile>/screenshots/*.jpg (evidence).
#
# Why 7 destinations: the destination list pages at 5 entries
# (DialogStatementGetResponsesPatch.DestinationsPerPage), so 7 is the smallest count that
# exercises both page boundaries - a full first page with a next-page row and no
# previous-page row, and a partial second page with the reverse.
#
# Usage: 05b-run-dialog-scenario.sh <profile>
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

SEED_COUNT=7
DESTINATIONS_PER_PAGE=5

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/dialog-result.json"
SCENARIO_FILE="$OUTPUT_DIR/scenario-result.json"
[ -f "$SCENARIO_FILE" ] || die "missing $SCENARIO_FILE (run 05-run-scenario.sh first)"

# Reuse the trader 05 already spawned and recorded. Talking to a *new* trader would make
# DialogGetFirstStatementPatch record another visit and change the server-side data 06
# checks; reusing this one keeps the dialog walkthrough side-effect free.
#
# VTT_DIALOG_TRADER_ID overrides it. run-language-sweep.sh sets it because entity ids are
# resolved per client session there: 05 runs once for the whole sweep, and by the time a
# later language's client has reconnected the id in scenario-result.json may no longer
# name a live entity.
TRADER_ID="${VTT_DIALOG_TRADER_ID:-}"
if [ -z "$TRADER_ID" ]; then
    TRADER_ID="$(jq -r '.trader_entity_ids.npcTraderBob' "$SCENARIO_FILE")"
fi
if [ -z "$TRADER_ID" ] || [ "$TRADER_ID" = "null" ]; then
    die "could not read npcTraderBob's entity id from $SCENARIO_FILE"
fi

REMOTE_SHOT_DIR="${OMEN_SCRATCH_DIR}\\screenshots"
# Filled in below, once the game has told us which language it actually loaded.
LOCAL_SHOT_DIR=""

# What 04-launch-client.sh was asked to launch with, if anything. Recorded in the result
# so 06-verify.sh can check the game honoured it - a client that quietly fell back to
# English would otherwise produce a perfectly green "localization test".
REQUESTED_LANGUAGE="${CLIENT_LANGUAGE:-}"

SHOT_NAMES=()

# take_screenshot <name>: fires the capture and waits for the file to actually appear.
# GameUtils.TakeScreenShot runs as a coroutine, so the console command returns long before
# the image is on disk - without the wait, collection below would race it.
take_screenshot() {
    local name="$1"
    local result
    result="$(submit_and_check "testpilot screenshot ${REMOTE_SHOT_DIR}\\${name}")"
    local ok
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "screenshot '$name' failed: $(printf '%s' "$result" | jq -r '.output')"
    wait_for_omen_file "${REMOTE_SHOT_DIR}\\${name}.jpg" 30 \
        || die "screenshot '$name' never appeared at ${REMOTE_SHOT_DIR}\\${name}.jpg"
    SHOT_NAMES+=("$name")
    log "captured screenshot: ${name}.jpg"
}

# dialog_cmd <subcommand...>: runs a vtttest dialog subcommand and dies unless it reported
# ok, printing the raw output so a failure is diagnosable without a rerun.
dialog_cmd() {
    local result
    result="$(submit_and_check "vtttest dialog $*")"
    local ok
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "vtttest dialog $* failed: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$result"
}

# player_state: {position, dead, health} for the local player, read from vanilla `le`.
#
# Worth the two extra queue round trips. The destination list is ordered by distance from
# the player, so anything that moves the player mid-walkthrough silently changes which
# entries land on which page - and the most likely mover is death: the respawn puts the
# player somewhere else and covers the screen with the respawn UI, while `vtttest dialog`
# keeps answering correctly because the dialog logic does not care. That combination
# produces green assertions next to a screenshot of a death screen, which was observed
# during a language sweep before this check existed.
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

# dialog_dump: returns the VTT_DIALOG_DUMP payload as JSON.
dialog_dump() {
    local result dump
    result="$(dialog_cmd dump)"
    dump="$(printf '%s' "$result" | jq -r '.output' | grep -oP '^VTT_DIALOG_DUMP \K.*' | tail -1 || true)"
    [ -n "$dump" ] || die "no VTT_DIALOG_DUMP marker in dump output: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$dump"
}

PLAYER_BEFORE="$(player_state)"
log "player before: $(printf '%s' "$PLAYER_BEFORE" | jq -c .)"

log "step: vtttest dialog open $TRADER_ID (npcTraderBob)"
dialog_cmd open "$TRADER_ID" >/dev/null
DUMP_START="$(dialog_dump)"

# Screenshots are filed under the language the game reports, not the one we asked for, so
# a sweep over several languages can't mislabel its own evidence.
ACTIVE_LANGUAGE="$(printf '%s' "$DUMP_START" | jq -r '.language // "unknown"')"
LOCAL_SHOT_DIR="$OUTPUT_DIR/screenshots/$ACTIVE_LANGUAGE"

# Start from an empty screenshot dir on both ends. Stale images from an earlier run are
# worse than none at all here: they are collected as this run's evidence and would be
# read as proof of something that never happened.
log "clearing screenshot directories (language: ${ACTIVE_LANGUAGE})..."
run_on_omen_cmd "Remove-Item '${REMOTE_SHOT_DIR}' -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '${REMOTE_SHOT_DIR}' | Out-Null"
rm -rf "$LOCAL_SHOT_DIR"
mkdir -p "$LOCAL_SHOT_DIR"

take_screenshot "01-dialog-start"

# Seed AFTER opening: DialogGetFirstStatementPatch.Postfix requests a fresh snapshot when
# the dialog opens, and that reply overwrites the client's destination list. Seeding first
# would lose the race against the server's own (much shorter) list.
log "step: vtttest dialog seed $SEED_COUNT"
dialog_cmd seed "$SEED_COUNT" >/dev/null

log "step: open the destination list (response vtt_open)"
dialog_cmd select vtt_open >/dev/null
DUMP_PAGE1="$(dialog_dump)"
take_screenshot "02-destinations-page1"

log "step: next page"
dialog_cmd select vtt_destination_page_next >/dev/null
DUMP_PAGE2="$(dialog_dump)"
take_screenshot "03-destinations-page2"

log "step: previous page"
dialog_cmd select vtt_destination_page_previous >/dev/null
DUMP_PAGE1_AGAIN="$(dialog_dump)"
take_screenshot "04-destinations-page1-again"

log "step: close the dialog"
dialog_cmd close >/dev/null

PLAYER_AFTER="$(player_state)"
log "player after: $(printf '%s' "$PLAYER_AFTER" | jq -c .)"

log "collecting screenshots to $LOCAL_SHOT_DIR..."
for name in "${SHOT_NAMES[@]}"; do
    copy_from_omen "${REMOTE_SHOT_DIR}\\${name}.jpg" "$LOCAL_SHOT_DIR/${name}.jpg" \
        || die "failed to collect screenshot ${name}.jpg"
done

SHOTS_JSON="$(printf '%s\n' "${SHOT_NAMES[@]}" | jq -R . | jq -s 'map(. + ".jpg")')"

jq -n \
    --arg trader_entity_id "$TRADER_ID" \
    --arg requested_language "$REQUESTED_LANGUAGE" \
    --arg screenshot_dir "${LOCAL_SHOT_DIR#"$ROOT_DIR/"}" \
    --argjson seed_count "$SEED_COUNT" \
    --argjson destinations_per_page "$DESTINATIONS_PER_PAGE" \
    --argjson start "$DUMP_START" \
    --argjson page1 "$DUMP_PAGE1" \
    --argjson page2 "$DUMP_PAGE2" \
    --argjson page1_again "$DUMP_PAGE1_AGAIN" \
    --argjson player_before "$PLAYER_BEFORE" \
    --argjson player_after "$PLAYER_AFTER" \
    --argjson screenshots "$SHOTS_JSON" \
    '{
        trader_entity_id: $trader_entity_id,
        requested_language: $requested_language,
        screenshot_dir: $screenshot_dir,
        seed_count: $seed_count,
        destinations_per_page: $destinations_per_page,
        player: {before: $player_before, after: $player_after},
        dumps: {start: $start, page1: $page1, page2: $page2, page1_again: $page1_again},
        screenshots: $screenshots
    }' > "$RESULT_FILE"

log "dialog scenario complete, results written to $RESULT_FILE"
