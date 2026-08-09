#!/usr/bin/env bash
# Judges the forget run recorded by 05f-run-forget-scenario.sh.
#
# Two things are easy to get wrong here and neither shows up as an error, so both are checked
# as sets rather than as counts: forgetting one destination must remove *that* one, and must
# leave the others exactly as they were.
#
# Usage: 06f-verify-forget.sh <profile>
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
RESULT_FILE="$OUTPUT_DIR/forget-result.json"
VERDICT_FILE="$OUTPUT_DIR/forget-verify.json"
rm -f "$VERDICT_FILE"
[ -f "$RESULT_FILE" ] || die "no $RESULT_FILE - run 05f-run-forget-scenario.sh first"

jq '
  .target.id as $target
| (.destinations.before | length) as $before_count
| {
    mode,
    target: .target,
    counts: {before: $before_count,
             after_cancel: (.destinations.after_cancel | length),
             after: (.destinations.after | length),
             after_revisit: (.destinations.after_revisit | length)},
    saved_visits,
    forget_prompt,

    # The entry has to be there to be worth removing.
    offered_before: ((.destinations.before | index($target)) != null),
    action_screen_offers_forget: .action_screen_offers_forget,

    # Backing out keeps everything. A confirmation that removes on either answer is worse
    # than no confirmation at all.
    cancel_kept_everything: (.destinations.after_cancel == .destinations.before),

    # Gone - and only it. Comparing the remainder as a set is what tells "forgot one" apart
    # from "cleared the list", which a count alone would not.
    target_is_gone: ((.destinations.after | index($target)) == null),
    others_untouched: (.destinations.after == (.destinations.before | map(select(. != $target)))),

    # The save is the part that survives a reload. The dialog can be right while the file is
    # wrong, and then the destination is back tomorrow.
    save_was_readable: (.saved_visits.before >= 0 and .saved_visits.after >= 0),
    save_lost_exactly_one: (.saved_visits.after == (.saved_visits.before - 1)),

    # Recoverable by walking back to the trader. Without this, "forget" is data loss.
    revisiting_brought_it_back: ((.destinations.after_revisit | index($target)) != null),

    # A prompt that never resolved would show the raw key.
    prompt_localized: ((.forget_prompt | length) > 0 and (.forget_prompt | test("vtt_") | not)),
    screenshots: (.screenshots | length),
    screenshot_dir
  }
| .ok = (.offered_before and .action_screen_offers_forget and .cancel_kept_everything
         and .target_is_gone and .others_untouched and .save_was_readable
         and .save_lost_exactly_one and .revisiting_brought_it_back and .prompt_localized)' \
    "$RESULT_FILE" > "$VERDICT_FILE"

jq -r '
    "forget verdict (" + .mode + "):",
    "  target:   \(.target.text)",
    "  list:     \(.counts.before) -> cancel \(.counts.after_cancel) -> forget \(.counts.after) -> revisit \(.counts.after_revisit)",
    "  save:     \(.saved_visits.before) -> \(.saved_visits.after) visits",
    "  prompt:   \"\(.forget_prompt)\""' "$VERDICT_FILE"

if [ "$(jq -r '.ok' "$VERDICT_FILE")" != "true" ]; then
    jq -r 'to_entries[] | select(.value == false) | "  FAILED: \(.key)"' "$VERDICT_FILE"
    die "forget verification failed (see $VERDICT_FILE)"
fi

log "forget verification passed"
