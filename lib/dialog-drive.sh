#!/usr/bin/env bash
# Driving the trader dialog through `testpilot dialog`, shared by every scenario that does it.
#
# These started as a copy in each scenario, which was tolerable while the copies agreed. They
# stopped agreeing the moment picking a destination began going through an action screen
# ("travel here / forget this destination / cancel") instead of departing immediately: three
# scenarios handled the extra screen because a confirmation could already appear there, and
# the fourth silently stopped travelling at all. Nothing errored - it just did not go
# anywhere, and the checks that noticed were two steps further on.
#
# Source after lib/common.sh and lib/testpilot-queue.sh.

# tp_dialog <args...>: run a dialog command, fail loudly if the driver says it did not work.
tp_dialog() {
    local result ok
    result="$(submit_and_check "testpilot dialog $*")"
    ok="$(vtt_result_field "$result" ok)"
    [ "$ok" = "true" ] || die "testpilot dialog $* failed: $(printf '%s' "$result" | jq -r '.output')"
    printf '%s' "$result"
}

# tp_dump_optional: the dialog's current contents, or nothing when no dialog is open. Used
# where "no dialog" is a legitimate answer - after travel the mod closes it.
tp_dump_optional() {
    local result
    result="$(submit_and_check "testpilot dialog dump" 2>/dev/null || true)"
    printf '%s' "$result" | jq -r '.output? // ""' 2>/dev/null \
        | grep -oP '^TESTPILOT_DIALOG_DUMP \K.*' | tail -1 || true
}

# tp_dialog_dump: the dialog's current contents; fails when nothing is open.
tp_dialog_dump() {
    local dump
    dump="$(tp_dump_optional)"
    [ -n "$dump" ] || die "no dialog is open"
    printf '%s' "$dump"
}

# dialog_destination_ids <dump>: the destination entries, without the paging controls.
dialog_destination_ids() {
    printf '%s' "$1" | jq -c '[.entries[].id
        | select(. != null)
        | select(startswith("vtt_destination_")
                 and . != "vtt_destination_page_next"
                 and . != "vtt_destination_page_previous")]'
}

# dialog_first_destination <dump>: the first destination offered, or empty.
dialog_first_destination() {
    dialog_destination_ids "$1" | jq -r 'first // empty'
}

# dialog_travel_to <destination response id>: picks the destination and completes the trip
# the way a player does, through whatever screens the mod puts in between.
#
# Prints what it had to click, so a scenario can record it: "travel" when the action screen
# appeared, "confirmed" when a confirmation was also required, "immediate" when the mod went
# straight there. A scenario asserting on that string would be asserting on the mod's
# configuration rather than on its behaviour, so none of them do.
dialog_travel_to() {
    local destination_id="$1"
    local dump path="immediate"

    tp_dialog select "$destination_id" >/dev/null
    sleep 2

    # The action screen. Its "travel here" entry kept the id the old yes/no confirmation used,
    # so this one branch covers both.
    dump="$(tp_dump_optional)"
    if printf '%s' "$dump" | jq -e '[.entries[].id] | any(. == "vtt_confirm_yes")' >/dev/null 2>&1; then
        path="travel"
        # A cost line means this is also a confirmation, which is worth recording separately.
        if printf '%s' "$dump" | jq -e '[.entries[].id] | any(. == "vtt_confirm_costline")' >/dev/null 2>&1; then
            path="confirmed"
        fi
        tp_dialog select vtt_confirm_yes >/dev/null
    fi

    printf '%s' "$path"
}

# dialog_forget <destination response id>: picks the destination and forgets it, through the
# action screen and the confirmation that follows.
dialog_forget() {
    local destination_id="$1"

    tp_dialog select "$destination_id" >/dev/null
    sleep 2
    tp_dialog select vtt_forget >/dev/null
    sleep 1
    tp_dialog select vtt_forget_yes >/dev/null
    sleep 2
}
