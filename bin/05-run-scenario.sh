#!/usr/bin/env bash
# Runs the default roundtrip scenario (see scenarios/default.txt) through the command
# queue: le -> spawn two traders near the player -> vtttest record (both) ->
# vtttest list -> vtttest teleport (between them) -> le. Writes
# output/<profile>/scenario-result.json.
# Usage: 05-run-scenario.sh <profile>
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

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/scenario-result.json"

# Nanosecond timestamp, not an incrementing counter: submit_and_check calls next_id
# inside a command substitution `$(...)`, which runs in a subshell - a counter variable
# incremented there would never be visible to the parent shell, so every call would
# silently return the same id and every command after the first would read back a
# stale out/<id>.result file instead of waiting for its own.
next_id() {
    date +%s%N
}

# submit_and_check <command text>: submits through the queue, dies on a queue-level
# timeout, prints the raw single-line result JSON.
submit_and_check() {
    local cmd="$1"
    local result
    result="$(testpilot_submit "$(next_id)" "$cmd")"
    if [[ "$result" == TIMEOUT* ]]; then
        die "command queue timed out submitting: $cmd"
    fi
    printf '%s' "$result"
}

# vtt_result_field <result_json> <field name>: pulls a field out of the VTT_TEST_RESULT
# marker embedded in .output (not the outer .ok, which only reflects whether
# SdtdConsole.ExecuteSync threw - see docs from the VisitedTraderTeleport repo).
# The trailing `|| true` on every grep below matters: with pipefail, a grep that finds
# no match exits non-zero and would otherwise kill the whole script via `set -e` before
# the caller gets a chance to check whether the result was actually empty.
vtt_result_field() {
    local result_json="$1"
    local field="$2"
    printf '%s' "$result_json" | jq -r '.output' | grep -oP "\"${field}\":\"?\K[^\",}]+" | tail -1 || true
}

log "step: le (initial)"
LE1_OUTPUT="$(submit_and_check "le" | jq -r '.output')"
PLAYER_ID="$(printf '%s' "$LE1_OUTPUT" | grep -oP 'EntityPlayerLocal.*?id=\K[0-9]+' | head -1 || true)"
[ -n "$PLAYER_ID" ] || die "could not find the local player's entity id in 'le' output"

# Spawn two distinct traders next to the player rather than teleporting to whatever
# destination happens to already be in the visit history. An earlier version of this
# scenario teleported to an existing recorded destination on the far side of the map,
# which landed the player in an unrelated, zombie-infested area and got them killed -
# a death that then persisted into the next test run. Spawning both trader targets
# right where the player already is keeps the whole round trip in a known-safe spot.
# See docs/lessons-learned.md.
log "spawning two traders near player id=$PLAYER_ID (npcTraderBob, npcTraderJen)"
submit_and_check "se ${PLAYER_ID} npcTraderBob 1" >/dev/null
submit_and_check "se ${PLAYER_ID} npcTraderJen 1" >/dev/null

LE2_OUTPUT="$(submit_and_check "le" | jq -r '.output')"
BOB_ID="$(printf '%s' "$LE2_OUTPUT" | grep -oP 'name=npcTraderBob, id=\K[0-9]+' | head -1 || true)"
JEN_ID="$(printf '%s' "$LE2_OUTPUT" | grep -oP 'name=npcTraderJen, id=\K[0-9]+' | head -1 || true)"
[ -n "$BOB_ID" ] || die "could not find or spawn npcTraderBob"
[ -n "$JEN_ID" ] || die "could not find or spawn npcTraderJen"
log "using trader entity ids: npcTraderBob=$BOB_ID npcTraderJen=$JEN_ID"

log "step: vtttest record $BOB_ID (npcTraderBob)"
RECORD="$(submit_and_check "vtttest record ${BOB_ID}")"
RECORD_OK="$(vtt_result_field "$RECORD" ok)"
[ "$RECORD_OK" = "true" ] || die "vtttest record failed: $(printf '%s' "$RECORD" | jq -r '.output')"
RECORD_RAW_KEY="$(vtt_result_field "$RECORD" detail)"

log "step: vtttest record $JEN_ID (npcTraderJen, second destination so the teleport below has a distinct - but still nearby and safe - target)"
RECORD2="$(submit_and_check "vtttest record ${JEN_ID}")"
RECORD2_OK="$(vtt_result_field "$RECORD2" ok)"
[ "$RECORD2_OK" = "true" ] || die "vtttest record (npcTraderJen) failed: $(printf '%s' "$RECORD2" | jq -r '.output')"

log "step: vtttest list"
LIST="$(submit_and_check "vtttest list")"
LIST_OUTPUT="$(printf '%s' "$LIST" | jq -r '.output')"
mapfile -t DEST_KEYS < <(printf '%s' "$LIST_OUTPUT" | grep -oP '^\[vtttest\] \K[^\t]+' || true)
[ "${#DEST_KEYS[@]}" -ge 2 ] || die "expected at least 2 destinations after recording two traders, got ${#DEST_KEYS[@]}: ${DEST_KEYS[*]:-<none>}"

# vtttest record's own reported key can lag the server-side canonicalization when run
# from a client (Record fires a network report and returns immediately, before the
# server's reply reflects back into the client-side destination cache - see
# docs/lessons-learned.md), so resolve the real key from 'list' by matching the raw
# key's npc-id prefix instead of trusting record's detail directly. This only works
# unambiguously because 03-deploy-mods.sh resets visit history before every run, so at
# most one destination per npc id can exist at this point.
RECORD_NPCID="${RECORD_RAW_KEY%%:*}"
RECORD_KEY=""
TELEPORT_KEY=""
for k in "${DEST_KEYS[@]}"; do
    if [ -z "$RECORD_KEY" ] && [[ "$k" == "${RECORD_NPCID}:"* ]]; then
        RECORD_KEY="$k"
    else
        TELEPORT_KEY="$k"
    fi
done
[ -n "$RECORD_KEY" ] || RECORD_KEY="$RECORD_RAW_KEY"
[ -n "$TELEPORT_KEY" ] || die "could not find a second destination distinct from $RECORD_KEY (both traders may have canonicalized into the same area)"

log "step: vtttest teleport $TELEPORT_KEY"
TELEPORT="$(submit_and_check "vtttest teleport ${TELEPORT_KEY}")"
TELEPORT_OK="$(vtt_result_field "$TELEPORT" ok)"
[ "$TELEPORT_OK" = "true" ] || die "vtttest teleport failed: $(printf '%s' "$TELEPORT" | jq -r '.output')"

# vtttest teleport returning ok:true only means the request was accepted - the actual
# move happens after a destination-chunk preparation window (see
# VisitedTraderTeleportService's "timeout=Ns" log line in the VisitedTraderTeleport
# repo), so an 'le' issued immediately after still shows the pre-teleport position.
log "waiting for the destination preparation window before confirming position..."
sleep 10

log "step: le (post-teleport)"
LE3_OUTPUT="$(submit_and_check "le" | jq -r '.output')"

jq -n \
    --arg bob_id "$BOB_ID" \
    --arg jen_id "$JEN_ID" \
    --arg record_raw_key "$RECORD_RAW_KEY" \
    --arg record_key "$RECORD_KEY" \
    --arg teleport_key "$TELEPORT_KEY" \
    --argjson record "$RECORD" \
    --argjson record2 "$RECORD2" \
    --argjson list "$LIST" \
    --argjson teleport "$TELEPORT" \
    --arg le_post_teleport "$LE3_OUTPUT" \
    '{
        trader_entity_ids: {npcTraderBob: $bob_id, npcTraderJen: $jen_id},
        record_raw_key: $record_raw_key,
        record_reported_key: $record_key,
        teleport_destination_key: $teleport_key,
        record: $record,
        record2: $record2,
        list: $list,
        teleport: $teleport,
        le_post_teleport: $le_post_teleport
    }' > "$RESULT_FILE"

log "scenario complete, results written to $RESULT_FILE"
