#!/usr/bin/env bash
# Checks who travel takes along and who it leaves behind, by looking at where things ended up.
#
# The companion rule decides two opposite things, and both had been unreachable from a script:
#
#   - a hired companion must still be gathered to the player (the regression direction - get
#     this wrong and companions are silently left behind);
#   - an owned turret must not be (the bug direction - issue #21, where turrets were uprooted
#     from bases on every trip).
#
# Neither can be set up through the game's own console. Hiring goes through NPC dialog, and a
# console-spawned turret comes out unowned (belongsPlayerId = -1) because ownership is
# assigned when a *player* places one. So `vtttest mark` writes the two markers directly:
#
#   mark hired <id>  -> the "Owner" Buffs custom var, exactly what SCore records on hire
#   mark owned <id>  -> belongsPlayerId, exactly what a placed turret gets
#
# Writing them by hand is the point: the *production* code then reads them the same way it
# reads the real thing. Nothing about the decision itself is stubbed.
#
# EVERYTHING ABOUT THE ENTITIES HAPPENS ON THE SERVER, and that took two wrong turns to
# establish. GatherCompanions runs server-side, so:
#
#   - a marker written through the client command queue lands on a copy the server never sees;
#   - and worse, an entity *spawned* through the client queue only exists on the client. Its
#     id means something different on the server, or nothing at all ("no living entity with
#     that id"). Spawning from the server console replicates to the client with the same id,
#     so the server is the only side worth spawning from.
#
# Which side that is depends on the topology, so everything goes through lib/world-console.sh
# rather than naming a helper directly. With a dedicated server it is the server; when the
# client hosts the world (TESTPILOT_MODE=hostload) there is no second process and it is the
# client. Both are worth running: travel takes a different branch for a local player than for
# a remote one, and each branch has its own GatherCompanions call site.
#
# The probe is still taken on both sides and both are recorded, so a marker that ends up in
# the wrong process announces itself instead of looking like a product bug. In hostload the
# two sides are the same process and simply agree.
#
# Writes output/<profile>/companion-result.json (asserted by 06c-verify-companions.sh) and,
# when something goes wrong, a screenshot of whatever the client was showing at the time.
#
# Usage: 05c-run-companion-scenario.sh <profile>
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
# shellcheck source=lib/docker-server.sh
source "$ROOT_DIR/lib/docker-server.sh"
# shellcheck source=lib/world-console.sh
source "$ROOT_DIR/lib/world-console.sh"
# shellcheck source=lib/dialog-drive.sh
source "$ROOT_DIR/lib/dialog-drive.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq grep awk docker
require_var OMEN_SCRATCH_DIR

# A trader stands in for the companion. GatherCompanions does not care what an entity is
# beyond what IsPlayerCompanion says about it, so any EntityAlive that is not an excluded type
# exercises the same path a hired NPC does - and traders exist on both game lines without
# depending on SCore or a modpack.
#
# Specifically a trader, and not the animal tried first, because a trader stays where it is
# put. The gather places companions within 1.8m of the player (CompanionSpotFinder), and a
# rabbit was reliably 20m away again by the time the positions were read - it had been
# gathered and had simply hopped off. With a stand-in that does not wander, any movement is
# the gather's doing.
#
# This one is deliberately not among the traders the scenario records, so it never becomes a
# travel destination.
COMPANION_PREFAB="npcTraderHugh"
# Class = EntityTurret, UserSpawnType = Console (entityclasses.xml): the real type the fix is
# about, not a stand-in.
TURRET_PREFAB="junkTurretGun"
# The companion is spawned next to the player rather than at a distance. Placing it far away
# was tried and is not reliable: spawnentityat takes literal coordinates with no ground
# snapping, so 60m along X lands in the air or inside rock depending on terrain, and the
# entity is gone by the time anything looks for it.
#
# The distance was only ever there to rule out "the rabbit wandered over by itself". That is
# covered better by the server's own account: GatherCompanions logs "Gathered N companion(s)"
# and nothing a wandering animal does produces that line. The positions are still recorded and
# checked, but the log line is the load-bearing evidence.

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/companion-result.json"
REMOTE_SHOT_DIR="${OMEN_SCRATCH_DIR}\\screenshots"
LOCAL_SHOT_DIR="$OUTPUT_DIR/screenshots/companion"

# A failure here is usually about what the game was doing, not about the numbers - a dead
# player, a spawn that landed inside a rock, a dialog still open. Capturing the screen on the
# way out costs one command and turns "the assertion said no" into something you can look at.
capture_on_failure() {
    local exit_code=$?
    [ "$exit_code" -eq 0 ] && return 0
    log "scenario failed (exit ${exit_code}); capturing the client's screen"
    mkdir -p "$LOCAL_SHOT_DIR"
    if submit_and_check "testpilot screenshot ${REMOTE_SHOT_DIR}\\failure" >/dev/null 2>&1 \
        && wait_for_omen_file "${REMOTE_SHOT_DIR}\\failure.jpg" 30 >/dev/null 2>&1 \
        && copy_from_omen "${REMOTE_SHOT_DIR}\\failure.jpg" "$LOCAL_SHOT_DIR/failure.jpg" >/dev/null 2>&1; then
        log "failure screenshot: $LOCAL_SHOT_DIR/failure.jpg"
    else
        log "warn: could not capture a failure screenshot (the client may already be gone)"
    fi
    return "$exit_code"
}
trap capture_on_failure EXIT

# Recording a visit and travelling both go through the trader dialog, driven from the client
# with `testpilot dialog` - the same commands 05r and 05t use. Not `vtttest`: that lives in
# the mod under test and so only exists in its Debug build, and this scenario has to be able
# to run against the packaged Release build. The dialog is also what a player actually does.
#
# These are client-side on purpose even when the world lives on a server: XUiC_DialogWindowGroup
# needs LocalPlayerUI, which only the client has.


# entity_position <le output> <entity id>: "x, y, z" as `le` printed it.
entity_position() {
    printf '%s' "$1" | grep -oP "id=$2\\], pos=\\(\\K[^)]+" | head -1 || true
}

# Both sides answer the same question about the same entities. They should agree; when they do
# not, the marker went to the wrong process.
# `jq -s .` already turns "no probe lines at all" into [], so the grep must not be allowed to
# fail the pipeline: under pipefail it did, the caller's `|| printf '[]'` then appended a
# *second* [] to output that was already complete, and the result was the invalid JSON
# "[]\n[]". Against a Release build there are never any probe lines, so this was the normal
# path, not an edge case.
probe_client() {
    { submit_and_check "vtttest companions" | jq -r '.output' \
        | grep -oP '^VTT_COMPANION_PROBE \K.*' || true; } | jq -s .
}

probe_world() {
    # The result marker comes after every probe line, so waiting for it means the whole
    # listing has arrived rather than however much of it fitted in a fixed window.
    { world_console "vtttest companions $1" 'VTT_TEST_RESULT {"action":"companions"' \
        | grep -oP 'VTT_COMPANION_PROBE \K\{.*' || true; } | jq -s .
}

player_state() {
    local le_line pos dead health
    le_line="$(world_le | grep -P '\[type=EntityPlayer(Local)?, name=' | head -1 || true)"
    [ -n "$le_line" ] || die "could not find the player in the 'le' output"
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

# spawn_and_find <prefab> <spawn command>: issues the spawn and waits until the entity is
# actually in the world, printing its id.
#
# A single spawn followed by a fixed sleep is not enough. The READY marker only means the
# primary player exists; a heavy modpack can still be on its loading screen, and a spawn
# issued then quietly does nothing. That failure was diagnosed in one look at the screenshot
# the scenario captures - the game was showing a loading tip - and retrying is the honest fix,
# since there is no readiness signal beyond "the thing I asked for is there".
# world_spawn_entity returns the id of the entity this call created, rather than the first
# one with that name: worlds ship with their own traders, and grabbing one of those is a
# valid id for the wrong entity - which then fails somewhere unrelated.
spawn_and_find() {
    local prefab="$1" command="$2" attempt id
    for attempt in 1 2; do
        if id="$(world_spawn_entity "$prefab" "$command")"; then
            [ "$attempt" -gt 1 ] && log "  ${prefab} appeared on attempt ${attempt}"
            printf '%s' "$id"
            return 0
        fi
        log "  ${prefab} not in the world yet (attempt ${attempt}); the world may still be loading"
    done
    return 1
}

log "step: le (locating the player, TESTPILOT_MODE=${TESTPILOT_MODE:-connect})"
LE="$(world_le)"
PLAYER_ID="$(world_player_id "$LE")"
[ -n "$PLAYER_ID" ] || die "could not find the player's entity id in the 'le' output"

# Spawns go to explicit coordinates rather than "near entity <id>". In a freshly hosted world
# the local player really is entity id 0 - confirmed in `le` - and `se 0 <class> 1` does
# nothing, silently. The player's own position is known-good ground, so spawning there needs
# no id at all and behaves the same in both topologies.
PLAYER_POS="$(entity_position "$LE" "$PLAYER_ID")"
[ -n "$PLAYER_POS" ] || die "could not read the player's position from 'le'"
PX="$(printf '%s' "$PLAYER_POS" | cut -d, -f1 | tr -d ' ')"
PY_="$(printf '%s' "$PLAYER_POS" | cut -d, -f2 | tr -d ' ')"
PZ="$(printf '%s' "$PLAYER_POS" | cut -d, -f3 | tr -d ' ')"
SPAWN_AT="${PX} ${PY_} ${PZ}"

PLAYER_BEFORE_STATE="$(player_state)"
log "player at start: $(printf '%s' "$PLAYER_BEFORE_STATE" | jq -c .)"
if [ "$(printf '%s' "$PLAYER_BEFORE_STATE" | jq -r '.dead')" = "true" ]; then
    die "the player is already dead in this save - run with --fresh-save"
fi

log "spawning the stand-in companion (${COMPANION_PREFAB}) next to the player"
COMPANION_ID="$(spawn_and_find "$COMPANION_PREFAB" "spawnentityat ${COMPANION_PREFAB} ${SPAWN_AT}")" \
    || die "could not find or spawn ${COMPANION_PREFAB} after several attempts - the world may not have finished loading"
log "spawning a turret (${TURRET_PREFAB}) next to the player"
TURRET_ID="$(spawn_and_find "$TURRET_PREFAB" "spawnentityat ${TURRET_PREFAB} ${SPAWN_AT}")" \
    || die "could not find or spawn ${TURRET_PREFAB} after several attempts"
log "companion id=${COMPANION_ID} turret id=${TURRET_ID}"

log "marking ${COMPANION_ID} as hired and ${TURRET_ID} as player-owned, where the world lives"
# The expect pattern doubles as the assertion: the marker line only appears when the harness
# actually wrote it, so a silent no-op cannot slip past as "the command was delivered".
# `testpilot mark`, not `vtttest mark`: it lives in SdtdTestPilot, which is a separate mod, so
# this works against a Release build of the mod under test. A harness compiled into that mod
# would only exist in its Debug build - and then the thing users download could never be the
# thing this scenario checked.
MARK_OK='TESTPILOT_RESULT {"action":"mark","ok":true'
# world_console dies if the marker line never appears, so reaching the next line is itself
# the proof that both markers were written. Recorded so the verdict can say so rather than
# leaning on the Debug-only probe for it.
world_console "testpilot mark hired ${COMPANION_ID} ${PLAYER_ID}" "$MARK_OK" >/dev/null
world_console "testpilot mark owned ${TURRET_ID} ${PLAYER_ID}" "$MARK_OK" >/dev/null
MARKERS_WRITTEN=true

# The probe reports what the mod's own IsPlayerCompanion decides, so it only exists in a Debug
# build. It is diagnostic: the verdict rests on what actually moved and on the game's own
# gather line, both of which a Release build produces. Empty here simply means "not available".
PROBE_SERVER="$(probe_world "$PLAYER_ID" 2>/dev/null || true)"
PROBE_CLIENT="$(probe_client 2>/dev/null || true)"
[ -n "$PROBE_SERVER" ] || PROBE_SERVER='[]'
[ -n "$PROBE_CLIENT" ] || PROBE_CLIENT='[]'
log "world probe: $(printf '%s' "$PROBE_SERVER" | jq -c '[.[] | {id: .entity_id, type, companion, would_match_ownership}]')"
log "client probe: $(printf '%s' "$PROBE_CLIENT" | jq -c '[.[] | {id: .entity_id, type, companion, would_match_ownership}]')"

# Both traders spawn at the player's position, so the trip lands on terrain already loaded -
# see docs/lessons-learned.md on why travelling somewhere far is how a test run kills a player.
# Spawned on the server for the same reason as everything else; the ids then mean the same
# thing to the client, which is what runs `vtttest record` and the travel.
log "spawning two traders and recording them from the client"
BOB_ID="$(spawn_and_find npcTraderBob "spawnentityat npcTraderBob ${SPAWN_AT}")" \
    || die "could not find or spawn npcTraderBob"
JEN_ID="$(spawn_and_find npcTraderJen "spawnentityat npcTraderJen ${SPAWN_AT}")" \
    || die "could not find or spawn npcTraderJen"
# Opening each trader's dialog is what records the visit - the mod's own patch does it, so
# this exercises the shipped build rather than a test-only shortcut.
log "recording both traders by opening their dialogs"
for id in "$BOB_ID" "$JEN_ID"; do
    tp_dialog open "$id" >/dev/null
    tp_dialog close >/dev/null
done

LE_BEFORE="$(world_le)"
PLAYER_POS_BEFORE="$(entity_position "$LE_BEFORE" "$PLAYER_ID")"
COMPANION_BEFORE="$(entity_position "$LE_BEFORE" "$COMPANION_ID")"
TURRET_BEFORE="$(entity_position "$LE_BEFORE" "$TURRET_ID")"
log "before travel - player:(${PLAYER_POS_BEFORE}) companion:(${COMPANION_BEFORE}) turret:(${TURRET_BEFORE})"

# Travel the way a player does: open Bob, pick the travel option, pick the one destination
# left in the list (the trader being talked to is filtered out of its own list, so that is
# Jen - standing where the player already is, on terrain that is already loaded).
log "travelling through the dialog"
tp_dialog open "$BOB_ID" >/dev/null
tp_dialog select vtt_open >/dev/null
DEST_DUMP="$(tp_dialog_dump)"
DEST_ID="$(dialog_first_destination "$DEST_DUMP")"
[ -n "$DEST_ID" ] || die "no destination offered in the dialog: $DEST_DUMP"
DEST_KEY="$(printf '%s' "$DEST_DUMP" | jq -r --arg id "$DEST_ID" '.entries[] | select(.id == $id) | .text')"
log "travelling to ${DEST_ID} (${DEST_KEY})"
log "  dialog path: $(dialog_travel_to "$DEST_ID")"
# The server prepares the destination before moving anyone, and the gather runs after arrival.
sleep 20

LE_AFTER="$(world_le)"
PLAYER_POS_AFTER="$(entity_position "$LE_AFTER" "$PLAYER_ID")"
COMPANION_AFTER="$(entity_position "$LE_AFTER" "$COMPANION_ID")"
TURRET_AFTER="$(entity_position "$LE_AFTER" "$TURRET_ID")"
log "after travel  - player:(${PLAYER_POS_AFTER}) companion:(${COMPANION_AFTER}) turret:(${TURRET_AFTER})"

if [ -z "$COMPANION_AFTER" ] || [ -z "$TURRET_AFTER" ]; then
    die "companion or turret is no longer in the entity list after travel (companion='${COMPANION_AFTER}' turret='${TURRET_AFTER}')"
fi

PLAYER_AFTER_STATE="$(player_state)"
log "player at end: $(printf '%s' "$PLAYER_AFTER_STATE" | jq -c .)"

# The game's own account of the gather, which is the thing under test rather than a reading
# of it. "Gathered N companion(s)" is only logged when N > 0. Which log that is depends on
# where the game is running - see world_log_grep_count.
GATHER_LOG="$(world_log_grep_count 'VisitedTraderTeleport\] Gathered')"
log "the game logged ${GATHER_LOG:-0} gather line(s)"

to_json_pos() { printf '%s' "$1" | jq -R 'split(", ") | map(tonumber)'; }

# jq reports a bad --argjson value as "invalid JSON text passed to --argjson" without saying
# *which* one, and with sixteen of them that is a guessing game. Check each first and name it.
json_arg() {
    local name="$1" value="$2"
    printf '%s' "$value" | jq -e . >/dev/null 2>&1 \
        || die "the scenario produced no usable value for ${name} (got '${value}')"
    printf '%s' "$value"
}

jq -n \
    --argjson player_id "$(json_arg player_id "$PLAYER_ID")" \
    --argjson companion_id "$(json_arg companion_id "$COMPANION_ID")" \
    --argjson turret_id "$(json_arg turret_id "$TURRET_ID")" \
    --arg destination_key "$DEST_KEY" \
    --argjson markers_written "$(json_arg markers_written "$MARKERS_WRITTEN")" \
    --argjson probe_server "$(json_arg probe_server "$PROBE_SERVER")" \
    --argjson probe_client "$(json_arg probe_client "$PROBE_CLIENT")" \
    --argjson gather_log_lines "$(json_arg gather_log_lines "${GATHER_LOG:-0}")" \
    --argjson player_state_before "$(json_arg player_state_before "$PLAYER_BEFORE_STATE")" \
    --argjson player_state_after "$(json_arg player_state_after "$PLAYER_AFTER_STATE")" \
    --argjson player_before "$(json_arg player_before "$(to_json_pos "$PLAYER_POS_BEFORE")")" \
    --argjson player_after "$(json_arg player_after "$(to_json_pos "$PLAYER_POS_AFTER")")" \
    --argjson companion_before "$(json_arg companion_before "$(to_json_pos "$COMPANION_BEFORE")")" \
    --argjson companion_after "$(json_arg companion_after "$(to_json_pos "$COMPANION_AFTER")")" \
    --argjson turret_before "$(json_arg turret_before "$(to_json_pos "$TURRET_BEFORE")")" \
    --argjson turret_after "$(json_arg turret_after "$(to_json_pos "$TURRET_AFTER")")" \
    '{
        player_id: $player_id,
        companion_id: $companion_id,
        turret_id: $turret_id,
        destination_key: $destination_key,
        markers_written: $markers_written,
        probe: {server: $probe_server, client: $probe_client},
        gather_log_lines: $gather_log_lines,
        player_state: {before: $player_state_before, after: $player_state_after},
        positions: {
            player: {before: $player_before, after: $player_after},
            companion: {before: $companion_before, after: $companion_after},
            turret: {before: $turret_before, after: $turret_after}
        }
    }' > "$RESULT_FILE"

log "companion scenario complete, results written to $RESULT_FILE"
