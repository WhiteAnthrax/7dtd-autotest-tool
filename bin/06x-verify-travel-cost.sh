#!/usr/bin/env bash
# Judges the travel-cost run recorded by 05x-run-travel-cost-scenario.sh.
#
# The number that matters is how many items left the player's inventory: exactly the cost, no
# more and no less. Everything else here supports that - a trip that did not happen would
# also spend nothing.
#
# Usage: 06x-verify-travel-cost.sh <profile>
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
RESULT_FILE="$OUTPUT_DIR/travel-cost-result.json"
VERDICT_FILE="$OUTPUT_DIR/travel-cost-verify.json"
rm -f "$VERDICT_FILE"
[ -f "$RESULT_FILE" ] || die "no $RESULT_FILE - run 05x-run-travel-cost-scenario.sh first"

jq '{
    mode,
    item,
    expected_cost,
    spent: .paying.spent,
    cannot_afford: .cannot_afford,
    paying: .paying,

    # Refused, and free of charge. A mod that took the items and then declined to travel would
    # be the worst outcome of the two, so both halves are asserted.
    broke_travel_refused: (.cannot_afford.teleports == 0),
    broke_nothing_taken: (.cannot_afford.items_after == .cannot_afford.items_before),

    # The trip happened once, and cost exactly what the settings say.
    paid_travel_happened: (.paying.teleports == 1),
    charged_exactly_the_cost: (.paying.spent == .expected_cost),

    # The mod noticed it charged someone, and did not report removing the wrong amount.
    # TravelCostService logs both of those cases itself.
    consumption_logged: (.paying.consumed_log_lines >= 1),
    no_over_removal: (.over_removals == 0),
    no_under_removal: (.under_removals == 0),

    # Confirmation mode is whenCost, so a paid trip must ask first - the branch no other
    # scenario reaches.
    confirmation_shown_when_paying: .paying.saw_confirmation,
    cost_line_readable: ((.paying.confirm_cost_text | length) > 0
                         and (.paying.confirm_cost_text | startswith("vtt_") | not)),
    screenshots: (.screenshots | length),
    screenshot_dir
}
| .ok = (.broke_travel_refused and .broke_nothing_taken and .paid_travel_happened
         and .charged_exactly_the_cost and .consumption_logged and .no_over_removal
         and .no_under_removal and .confirmation_shown_when_paying and .cost_line_readable)' \
    "$RESULT_FILE" > "$VERDICT_FILE"

jq -r '
    "travel cost verdict (" + .mode + "):",
    "  item:        \(.item), a trip costs \(.expected_cost)",
    "  cannot pay:  \(.cannot_afford.items_before) -> \(.cannot_afford.items_after) items, \(.cannot_afford.teleports) trips",
    "  paying:      \(.paying.items_before) -> \(.paying.items_after) items (spent \(.paying.spent)), \(.paying.teleports) trips",
    "  confirmed:   \(.paying.saw_confirmation), cost line \"\(.paying.confirm_cost_text)\""' "$VERDICT_FILE"

if [ "$(jq -r '.ok' "$VERDICT_FILE")" != "true" ]; then
    jq -r 'to_entries[] | select(.value == false) | "  FAILED: \(.key)"' "$VERDICT_FILE"
    die "travel cost verification failed (see $VERDICT_FILE)"
fi

log "travel cost verification passed"
