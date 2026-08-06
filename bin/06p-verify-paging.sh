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

jq '
  (.pages | length) as $page_count
| ([.pages[] | length] | add) as $listed
| ([.pages[][]] | unique | length) as $distinct
| .per_page as $per_page
| {
    mode,
    per_page,
    page_count: $page_count,
    page_sizes: [.pages[] | length],
    total_listed: $listed,
    labels,

    # There was more than one page. Without this everything below is vacuously true.
    paged_at_all: ($page_count >= 2),

    # Every page but the last is full, and the last is neither empty nor overfull.
    full_pages_are_full: ([.pages[:-1][] | length] | all(. == $per_page)),
    last_page_in_range: ((.pages[-1] | length) > 0 and (.pages[-1] | length) <= .per_page),

    # Nothing shown twice, which is what an off-by-one in the slice would produce.
    no_duplicates_across_pages: ($listed == $distinct),

    # The controls match where you are: the first page offers next only, the last offers
    # previous only, anything between offers both.
    controls_match_position: ([.page_controls | to_entries[]
        | .key as $i
        | (.value.has_next == ($i < ($page_count - 1)))
          and (.value.has_previous == ($i > 0))] | all),

    # Going back one page from the last shows the page before it, in the same order.
    back_matches_previous_page: (.back_one_page == .pages[-2]),

    # Readable text rather than a key that never resolved.
    paging_labels_localized: ((.labels.next | length) > 0
                              and (.labels.previous | length) > 0
                              and (.labels.next | startswith("vtt_") | not)
                              and (.labels.previous | startswith("vtt_") | not)),
    screenshots: (.screenshots | length),
    screenshot_dir
  }
| .ok = (.paged_at_all and .full_pages_are_full and .last_page_in_range
         and .no_duplicates_across_pages and .controls_match_position
         and .back_matches_previous_page and .paging_labels_localized)' \
    "$RESULT_FILE" > "$VERDICT_FILE"

jq -r '
    "paging verdict (" + .mode + "):",
    "  pages:    \(.page_sizes | map(tostring) | join(" + ")) = \(.total_listed) destinations over \(.page_count) pages (\(.per_page) per page)",
    "  labels:   next=\"\(.labels.next)\" previous=\"\(.labels.previous)\""' "$VERDICT_FILE"

if [ "$(jq -r '.ok' "$VERDICT_FILE")" != "true" ]; then
    jq -r 'to_entries[] | select(.value == false) | "  FAILED: \(.key)"' "$VERDICT_FILE"
    die "paging verification failed (see $VERDICT_FILE)"
fi

log "paging verification passed"
