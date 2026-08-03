#!/usr/bin/env bash
# Checks output/<profile>/companion-result.json - who travel took along and who it left.
#
# Usage: 06c-verify-companions.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

# Surface `set -e` failures instead of exiting silently (see lib/common.sh).
trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
RESULT_FILE="$OUTPUT_DIR/companion-result.json"
[ -f "$RESULT_FILE" ] || die "missing $RESULT_FILE (run 05c-run-companion-scenario.sh first)"
VERIFY_FILE="$OUTPUT_DIR/companion-verify.json"

# The companion is gathered to wherever the player ended up, so "followed" is measured
# against the player's own arrival point rather than against how far it moved - the trip is
# deliberately short (both traders spawn at the player's feet), so distance travelled proves
# nothing on its own.
#
# CompanionSpotFinder places companions in a ring around the player, so allow a few metres.
VERDICT="$(jq '
    def dist($a; $b):
        (($a[0] - $b[0]) as $dx | ($a[1] - $b[1]) as $dy | ($a[2] - $b[2]) as $dz
         | ($dx * $dx + $dy * $dy + $dz * $dz) | sqrt | . * 100 | round / 100);

    {
        # The probe reads the mod IsPlayerCompanion decision itself, so it only exists in a
        # Debug build and is absent when this runs against a shipped package. It is diagnostic
        # either way: what carries the verdict is that both markers were written, that
        # something actually moved, and that the game logged a gather.
        # (No apostrophes in here - the whole program is inside a single-quoted shell string.)
        probe_available: ((.probe.server | length) > 0),
        markers_written: (.markers_written // false),
        # The server probe is the one that counts - GatherCompanions runs there. The client
        # probe is recorded next to it so a marker written to the wrong process shows up as a
        # disagreement rather than as a mysterious product failure.
        companion_is_companion: ([.probe.server[] | select(.companion == true)] | length),
        companion_is_companion_client: ([.probe.client[] | select(.companion == true)] | length),
        turret_would_match_ownership: ([.probe.server[] | select(.type == "EntityTurret" and .would_match_ownership == true)] | length),
        turret_is_companion: ([.probe.server[] | select(.type == "EntityTurret" and .companion == true)] | length),
        gather_log_lines: .gather_log_lines,
        player_alive: ((.player_state.before.dead | not) and (.player_state.after.dead | not)),
        companion_to_player_before: dist(.positions.companion.before; .positions.player.before),
        companion_to_player_after: dist(.positions.companion.after; .positions.player.after),
        companion_moved: dist(.positions.companion.before; .positions.companion.after),
        turret_moved: dist(.positions.turret.before; .positions.turret.after),
        player_moved: dist(.positions.player.before; .positions.player.after)
      }
    # The regression direction: a hired companion still ends up next to the player.
    | .companion_followed = (.companion_to_player_after <= 8)
    # The bug direction (#21): an owned turret stayed exactly where it was placed.
    | .turret_stayed = (.turret_moved <= 1)
    # And the setup was real - the turret did carry the ownership marker the old rule read,
    # so this is the situation that used to drag it along, not a turret that never qualified.
    | .turret_setup_was_the_bug_condition = (if .probe_available then .turret_would_match_ownership >= 1 else .markers_written end)
    # Only answerable with the probe. Without it the behavioural check carries this: an owned
    # turret that the rule accepted would have been moved, and turret_stayed catches that.
    | .turret_not_a_companion = (if .probe_available then .turret_is_companion == 0 else true end)
    # With the probe: the mod itself says this is a companion. Without it: the marker a real
    # hire writes was written, which is the same setup - the difference is only whether the
    # mod can be asked directly.
    | .companion_recognised = (if .probe_available then .companion_is_companion >= 1 else .markers_written end)
    # The load-bearing one. GatherCompanions logs "Gathered N companion(s)" only when it moved
    # something, so this comes from the code under test rather than from a reading of where an
    # entity happens to be - and unlike a position check it cannot be satisfied by a stand-in
    # that wandered into place.
    | .gather_ran = (.gather_log_lines >= 1)
    | .ok = (
        .companion_recognised
        and .companion_followed
        and .turret_setup_was_the_bug_condition
        and .turret_not_a_companion
        and .turret_stayed
        and .gather_ran
        and .player_alive
      )
' "$RESULT_FILE")"

printf '%s\n' "$VERDICT" > "$VERIFY_FILE"
OK="$(printf '%s' "$VERDICT" | jq -r '.ok')"

if [ "$OK" != "true" ]; then
    log "companion verification FAILED:"
    printf '%s\n' "$VERDICT"
    die "companion verification failed (details in $VERIFY_FILE)"
fi

log "companion verification passed: $(printf '%s' "$VERDICT" | jq -r '"companion came \(.companion_moved)m to within \(.companion_to_player_after)m of the player (started \(.companion_to_player_before)m away), turret moved \(.turret_moved)m"')"
