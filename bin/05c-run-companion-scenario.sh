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

vtt_cmd() {
    local result ok
    result="$(submit_and_check "vtttest $*")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "vtttest $* failed: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$result"
}

# entity_position <le output> <entity id>: "x, y, z" as `le` printed it.
entity_position() {
    printf '%s' "$1" | grep -oP "id=$2\\], pos=\\(\\K[^)]+" | head -1 || true
}

# Both sides answer the same question about the same entities. They should agree; when they do
# not, the marker went to the wrong process.
probe_client() {
    submit_and_check "vtttest companions" | jq -r '.output' \
        | grep -oP '^VTT_COMPANION_PROBE \K.*' | jq -s .
}

probe_world() {
    # The result marker comes after every probe line, so waiting for it means the whole
    # listing has arrived rather than however much of it fitted in a fixed window.
    world_console "vtttest companions $1" 'VTT_TEST_RESULT {"action":"companions"' \
        | grep -oP 'VTT_COMPANION_PROBE \K\{.*' | jq -s .
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

log "step: le (locating the player, TESTPILOT_MODE=${TESTPILOT_MODE:-connect})"
LE="$(world_le)"
PLAYER_ID="$(world_player_id "$LE")"
[ -n "$PLAYER_ID" ] || die "could not find the player's entity id in the 'le' output"

PLAYER_BEFORE_STATE="$(player_state)"
log "player at start: $(printf '%s' "$PLAYER_BEFORE_STATE" | jq -c .)"
if [ "$(printf '%s' "$PLAYER_BEFORE_STATE" | jq -r '.dead')" = "true" ]; then
    die "the player is already dead in this save - run with --fresh-save"
fi

log "spawning the stand-in companion (${COMPANION_PREFAB}) next to the player on the server"
world_console "se ${PLAYER_ID} ${COMPANION_PREFAB} 1" "Spawned" 20 >/dev/null
log "spawning a turret (${TURRET_PREFAB}) next to the player on the server"
world_console "se ${PLAYER_ID} ${TURRET_PREFAB} 1" "Spawned" 20 >/dev/null
sleep 3

LE="$(world_le)"
COMPANION_ID="$(printf '%s' "$LE" | grep -oP "name=${COMPANION_PREFAB}, id=\K[0-9]+" | head -1 || true)"
TURRET_ID="$(printf '%s' "$LE" | grep -oP "name=${TURRET_PREFAB}, id=\K[0-9]+" | head -1 || true)"
[ -n "$COMPANION_ID" ] || die "could not find or spawn ${COMPANION_PREFAB}"
[ -n "$TURRET_ID" ] || die "could not find or spawn ${TURRET_PREFAB}"
log "companion id=${COMPANION_ID} turret id=${TURRET_ID}"

log "marking ${COMPANION_ID} as hired and ${TURRET_ID} as player-owned, where the world lives"
# The expect pattern doubles as the assertion: the marker line only appears when the harness
# actually wrote it, so a silent no-op cannot slip past as "the command was delivered".
MARK_OK='VTT_TEST_RESULT {"action":"mark","ok":true'
world_console "vtttest mark hired ${COMPANION_ID} ${PLAYER_ID}" "$MARK_OK" >/dev/null
world_console "vtttest mark owned ${TURRET_ID} ${PLAYER_ID}" "$MARK_OK" >/dev/null

PROBE_SERVER="$(probe_world "$PLAYER_ID")"
PROBE_CLIENT="$(probe_client)"
log "world probe: $(printf '%s' "$PROBE_SERVER" | jq -c '[.[] | {id: .entity_id, type, companion, would_match_ownership}]')"
log "client probe: $(printf '%s' "$PROBE_CLIENT" | jq -c '[.[] | {id: .entity_id, type, companion, would_match_ownership}]')"

# Both traders spawn at the player's position, so the trip lands on terrain already loaded -
# see docs/lessons-learned.md on why travelling somewhere far is how a test run kills a player.
# Spawned on the server for the same reason as everything else; the ids then mean the same
# thing to the client, which is what runs `vtttest record` and the travel.
log "spawning two traders on the server and recording them from the client"
world_console "se ${PLAYER_ID} npcTraderBob 1" "Spawned" 20 >/dev/null
world_console "se ${PLAYER_ID} npcTraderJen 1" "Spawned" 20 >/dev/null
sleep 3
LE="$(world_le)"
BOB_ID="$(printf '%s' "$LE" | grep -oP 'name=npcTraderBob, id=\K[0-9]+' | head -1 || true)"
JEN_ID="$(printf '%s' "$LE" | grep -oP 'name=npcTraderJen, id=\K[0-9]+' | head -1 || true)"
if [ -z "$BOB_ID" ] || [ -z "$JEN_ID" ]; then
    die "could not find or spawn both traders"
fi
vtt_cmd record "$BOB_ID" >/dev/null
vtt_cmd record "$JEN_ID" >/dev/null

DEST_KEY="$(submit_and_check "vtttest list" | jq -r '.output' \
    | grep -oP '^\[vtttest\] \K[^\t]+' | tail -1 || true)"
[ -n "$DEST_KEY" ] || die "no destination to travel to after recording two traders"

LE_BEFORE="$(world_le)"
PLAYER_POS_BEFORE="$(entity_position "$LE_BEFORE" "$PLAYER_ID")"
COMPANION_BEFORE="$(entity_position "$LE_BEFORE" "$COMPANION_ID")"
TURRET_BEFORE="$(entity_position "$LE_BEFORE" "$TURRET_ID")"
log "before travel - player:(${PLAYER_POS_BEFORE}) companion:(${COMPANION_BEFORE}) turret:(${TURRET_BEFORE})"

log "step: vtttest teleport ${DEST_KEY}"
vtt_cmd teleport "$DEST_KEY" >/dev/null
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

jq -n \
    --argjson player_id "$PLAYER_ID" \
    --argjson companion_id "$COMPANION_ID" \
    --argjson turret_id "$TURRET_ID" \
    --arg destination_key "$DEST_KEY" \
    --argjson probe_server "$PROBE_SERVER" \
    --argjson probe_client "$PROBE_CLIENT" \
    --argjson gather_log_lines "${GATHER_LOG:-0}" \
    --argjson player_state_before "$PLAYER_BEFORE_STATE" \
    --argjson player_state_after "$PLAYER_AFTER_STATE" \
    --argjson player_before "$(to_json_pos "$PLAYER_POS_BEFORE")" \
    --argjson player_after "$(to_json_pos "$PLAYER_POS_AFTER")" \
    --argjson companion_before "$(to_json_pos "$COMPANION_BEFORE")" \
    --argjson companion_after "$(to_json_pos "$COMPANION_AFTER")" \
    --argjson turret_before "$(to_json_pos "$TURRET_BEFORE")" \
    --argjson turret_after "$(to_json_pos "$TURRET_AFTER")" \
    '{
        player_id: $player_id,
        companion_id: $companion_id,
        turret_id: $turret_id,
        destination_key: $destination_key,
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
