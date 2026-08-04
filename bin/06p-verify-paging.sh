#!/usr/bin/env bash
# Judges the paged destination list recorded by 05p-run-paging-scenario.sh.
#
# The interesting failures here are not "no second page" but the quiet ones: an entry that
# appears on both pages, or one that appears on neither because an off-by-one skipped it. So
# the pages are compared as sets against the total, not just counted.
#
# Usage: 06p-verify-paging.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_cmd jq

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
RESULT_FILE="$OUTPUT_DIR/paging-result.json"
VERDICT_FILE="$OUTPUT_DIR/paging-verify.json"
rm -f "$VERDICT_FILE"
[ -f "$RESULT_FILE" ] || die "no $RESULT_FILE - run 05p-run-paging-scenario.sh first"

jq '{
    mode,
    expected_total,
    per_page,
    page1_count: (.pages.first | length),
    page2_count: (.pages.second | length),
    controls,

    first_page_is_full: ((.pages.first | length) == .per_page),
    second_page_has_the_rest: ((.pages.second | length) == (.expected_total - .per_page)),

    # Every destination appears exactly once across the two pages.
    no_duplicates_across_pages: (((.pages.first + .pages.second) | unique | length)
                                 == ((.pages.first + .pages.second) | length)),
    all_destinations_shown: (((.pages.first + .pages.second) | unique | length) == .expected_total),

    # The controls offered match where you are in the list.
    next_on_first_page: .controls.page1_has_next,
    no_previous_on_first_page: (.controls.page1_has_previous | not),
    previous_on_second_page: .controls.page2_has_previous,
    no_next_on_last_page: (.controls.page2_has_next | not),

    # Going back is the same page, in the same order, rather than a re-slice from somewhere.
    back_matches_first_page: (.pages.back_to_first == .pages.first),

    # The paging entries are text a player can read, not a raw key that never resolved.
    paging_labels_localized: ((.controls.next_text | length) > 0
                              and (.controls.previous_text | length) > 0
                              and (.controls.next_text | startswith("vtt_") | not)
                              and (.controls.previous_text | startswith("vtt_") | not)),
    screenshots: (.screenshots | length),
    screenshot_dir
}
| .ok = (.first_page_is_full and .second_page_has_the_rest and .no_duplicates_across_pages
         and .all_destinations_shown and .next_on_first_page and .no_previous_on_first_page
         and .previous_on_second_page and .no_next_on_last_page and .back_matches_first_page
         and .paging_labels_localized)' "$RESULT_FILE" > "$VERDICT_FILE"

jq -r '
    "paging verdict (" + .mode + "):",
    "  pages:    \(.page1_count) + \(.page2_count) of \(.expected_total) destinations (\(.per_page) per page)",
    "  controls: next=\(.controls.page1_has_next)/\(.controls.page2_has_next) previous=\(.controls.page1_has_previous)/\(.controls.page2_has_previous)",
    "  labels:   next=\"\(.controls.next_text)\" previous=\"\(.controls.previous_text)\""' "$VERDICT_FILE"

if [ "$(jq -r '.ok' "$VERDICT_FILE")" != "true" ]; then
    jq -r 'to_entries[] | select(.value == false) | "  FAILED: \(.key)"' "$VERDICT_FILE"
    die "paging verification failed (see $VERDICT_FILE)"
fi

log "paging verification passed"
