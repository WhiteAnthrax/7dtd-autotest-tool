#!/usr/bin/env bash
# Checks output/<profile>/release-dialog-result.json - the walkthrough 05r ran against the
# packaged Release build.
#
# Deliberately a separate script from 06-verify.sh rather than a mode of it. The two check
# different things: 06 asserts paging boundaries against a seeded list, which a Release
# build cannot produce because seeding needs the mod's internals. The definitions below are
# the subset that applies to both; keep them in step with 06-verify.sh if either changes.
#
# Usage: 06r-verify-release.sh <profile>
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
RESULT_FILE="$OUTPUT_DIR/release-dialog-result.json"
# Hard requirement, like 06's: a check that silently skips itself is indistinguishable from
# one that passed.
[ -f "$RESULT_FILE" ] || die "missing $RESULT_FILE (run 05r-run-release-dialog-scenario.sh first)"

VERIFY_FILE="$OUTPUT_DIR/release-verify-result.json"

VERDICT="$(jq '
    def dest_ids:
        [.entries[].id
         | select(. != null)
         | select(startswith("vtt_destination_")
                  and . != "vtt_destination_page_next"
                  and . != "vtt_destination_page_previous")];
    def has_id($id): [.entries[].id] | any(. == $id);
    def rendered_ok: (.rendered | length) == (.entries | length);
    def unresolved:
        [.entries[]
         | select(.text != null and (.text | test("vtt_[a-z0-9_]+")))
         | {id: .id, text: .text}];
    def dist($a; $b):
        (($a[0] - $b[0]) as $dx | ($a[1] - $b[1]) as $dy | ($a[2] - $b[2]) as $dz
         | ($dx * $dx + $dy * $dy + $dz * $dz) | sqrt);

    (.expected_destinations) as $expected
    | {
        travel_option_offered: (.dumps.start | has_id("vtt_open")),
        destinations: (.dumps.destinations | dest_ids | length),
        expected_destinations: $expected,
        rendered_matches_logical: ((.dumps.start | rendered_ok) and (.dumps.destinations | rendered_ok)),
        unresolved_keys: ([.dumps[] | unresolved] | flatten),
        requested_language: (.requested_language // ""),
        language: (.dumps.destinations.language),
        screenshot_dir: (.screenshot_dir // null),
        screenshots: (.screenshots | length),
        player_alive: ((.player.before.dead | not) and (.player.after.dead | not)),
        player_moved_m: (dist(.player.before.position; .player.after.position) | . * 100 | round / 100)
      }
    | .language_as_requested = (.requested_language == "" or .requested_language == .language)
    | .player_stayed_put = (.player_moved_m <= 2)
    | .ok = (
        .travel_option_offered
        and .destinations == $expected
        and .rendered_matches_logical
        and (.unresolved_keys | length) == 0
        and .language_as_requested
        and .player_alive
        and .player_stayed_put
        and .screenshots == 2
      )
' "$RESULT_FILE")"

printf '%s\n' "$VERDICT" > "$VERIFY_FILE"
OK="$(printf '%s' "$VERDICT" | jq -r '.ok')"

if [ "$OK" != "true" ]; then
    log "release-package verification FAILED:"
    printf '%s\n' "$VERDICT"
    die "release-package verification failed (details in $VERIFY_FILE)"
fi

log "release-package verification passed: $(printf '%s' "$VERDICT" | jq -r '"destinations=\(.destinations) language=\(.language) screenshots=\(.screenshots)"')"
