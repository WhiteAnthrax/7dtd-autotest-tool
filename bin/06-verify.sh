#!/usr/bin/env bash
# Verifies both halves of a run:
#
#   1. Server data - output/<profile>/scenario-result.json against the server-side
#      VisitedTraderTeleportData.json: the recorded destination key must exist in Traders
#      and be attributed to some player in VisitsByPlayer.
#   2. Trader dialog - output/<profile>/dialog-result.json: the paging boundaries, that
#      nothing the dialog produced was dropped before it reached the screen, and that no
#      text rendered as a raw localization key.
#
# Usage: 06-verify.sh <profile>
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
require_cmd jq find

require_var SERVER_SAVES_DIR
require_var GAME_SAVE_NAME
OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
RESULT_FILE="$OUTPUT_DIR/scenario-result.json"
[ -f "$RESULT_FILE" ] || die "missing $RESULT_FILE (run 05-run-scenario.sh first)"

# Match on GAME_SAVE_NAME, not "newest file under SERVER_SAVES_DIR" - see the comment in
# 03-deploy-mods.sh for why the latter picks up unrelated worlds on this shared machine.
# Follows 01-start-server.sh's --fresh-save throwaway save when there is one.
SAVE_NAME="$(effective_game_save_name "$OUTPUT_DIR")"
DATA_FILE="$(find "$SERVER_SAVES_DIR" -path "*/${SAVE_NAME}/VisitedTraderTeleportData.json" 2>/dev/null | head -1)"
[ -n "$DATA_FILE" ] || die "no VisitedTraderTeleportData.json found under $SERVER_SAVES_DIR for save name '$SAVE_NAME'"
log "using server-side data file: $DATA_FILE"

RECORD_KEY="$(jq -r '.record_reported_key' "$RESULT_FILE")"

KEY_IN_TRADERS="$(jq --arg k "$RECORD_KEY" '.Traders | has($k)' "$DATA_FILE")"
KEY_VISITED_BY_SOMEONE="$(jq --arg k "$RECORD_KEY" '[.VisitsByPlayer[] | any(. == $k)] | any' "$DATA_FILE")"

DATA_OK=false
if [ "$KEY_IN_TRADERS" = "true" ] && [ "$KEY_VISITED_BY_SOMEONE" = "true" ]; then
    DATA_OK=true
fi

# --- Trader dialog ---
# Deliberately a hard requirement rather than "verify it if the file happens to be there":
# a dialog check that silently skips itself is indistinguishable from one that passed.
DIALOG_FILE="$OUTPUT_DIR/dialog-result.json"
[ -f "$DIALOG_FILE" ] || die "missing $DIALOG_FILE (run 05b-run-dialog-scenario.sh first)"

# dest_ids drops the two paging rows, which share the vtt_destination_ prefix with the
# real entries because CreatePageEntry reuses it.
#
# rendered vs entries is the check that catches a dialog skin with fewer response slots
# than the mod produced: XUiC_DialogResponseList.Update silently drops everything past the
# last slot, so the logical list can be right while the screen shows a truncated one.
#
# unresolved catches text that reached the screen as a raw localization key: no localized
# string legitimately contains "vtt_", so any occurrence means a lookup fell through.
DIALOG_JSON="$(jq '
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

    (.destinations_per_page) as $per_page
    | (.seed_count - $per_page) as $page2_expected
    | {
        page1_destinations: (.dumps.page1 | dest_ids | length),
        page1_has_next: (.dumps.page1 | has_id("vtt_destination_page_next")),
        page1_has_previous: (.dumps.page1 | has_id("vtt_destination_page_previous")),
        page2_destinations: (.dumps.page2 | dest_ids | length),
        page2_has_next: (.dumps.page2 | has_id("vtt_destination_page_next")),
        page2_has_previous: (.dumps.page2 | has_id("vtt_destination_page_previous")),
        paging_returns_same_page: ((.dumps.page1 | dest_ids) == (.dumps.page1_again | dest_ids)),
        rendered_matches_logical: ((.dumps.page1 | rendered_ok) and (.dumps.page2 | rendered_ok)),
        unresolved_keys: ([.dumps[] | unresolved] | flatten),
        requested_language: (.requested_language // ""),
        language: (.dumps.page1.language),
        screenshot_dir: (.screenshot_dir // null),
        screenshots: (.screenshots | length)
      }
    | .expected_page1_destinations = $per_page
    | .expected_page2_destinations = $page2_expected
    # An unhonoured -language= argument is the one failure a localization run cannot
    # afford to miss: the client falls back to its configured language and every other
    # assertion still passes, so the run would certify text nobody ever looked at.
    | .language_as_requested = (.requested_language == "" or .requested_language == .language)
    | .ok = (
        .page1_destinations == $per_page
        and .page1_has_next
        and (.page1_has_previous | not)
        and .page2_destinations == $page2_expected
        and (.page2_has_next | not)
        and .page2_has_previous
        and .paging_returns_same_page
        and .rendered_matches_logical
        and (.unresolved_keys | length) == 0
        and .language_as_requested
      )
' "$DIALOG_FILE")"

DIALOG_OK="$(printf '%s' "$DIALOG_JSON" | jq -r '.ok')"

VERIFY_OK=false
if [ "$DATA_OK" = "true" ] && [ "$DIALOG_OK" = "true" ]; then
    VERIFY_OK=true
fi

jq -n \
    --arg data_file "$DATA_FILE" \
    --arg record_key "$RECORD_KEY" \
    --argjson key_in_traders "$KEY_IN_TRADERS" \
    --argjson key_visited "$KEY_VISITED_BY_SOMEONE" \
    --argjson data_ok "$DATA_OK" \
    --argjson dialog "$DIALOG_JSON" \
    --argjson ok "$VERIFY_OK" \
    '{data_file: $data_file, record_key: $record_key, key_in_traders: $key_in_traders,
      key_visited_by_someone: $key_visited, data_ok: $data_ok, dialog: $dialog, ok: $ok}' \
    > "$OUTPUT_DIR/verify-result.json"

if [ "$DATA_OK" != "true" ]; then
    log "server-data verification FAILED: '$RECORD_KEY' not found as expected in $DATA_FILE (key_in_traders=$KEY_IN_TRADERS, key_visited=$KEY_VISITED_BY_SOMEONE)"
else
    log "server-data verification passed: '$RECORD_KEY' is present in $DATA_FILE"
fi

if [ "$DIALOG_OK" != "true" ]; then
    log "dialog verification FAILED:"
    printf '%s\n' "$DIALOG_JSON" | jq . >&2
else
    log "dialog verification passed: $(printf '%s' "$DIALOG_JSON" | jq -r '"page1=\(.page1_destinations) page2=\(.page2_destinations) language=\(.language) screenshots=\(.screenshots)"')"
fi

[ "$VERIFY_OK" = "true" ]
