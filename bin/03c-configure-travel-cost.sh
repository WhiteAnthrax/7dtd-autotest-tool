#!/usr/bin/env bash
# Turns on the mod's travel cost, the way a user would: by editing the installed
# Config/VisitedTraderTeleport.xml.
#
# It has to run between 03-deploy-mods.sh and 04-launch-client.sh, because the mod reads that
# file when the world loads. There is no reload command, so a scenario that edits it after the
# game is up would be testing the shipped default (cost disabled) while believing otherwise.
#
# The DLL is untouched - this is configuration, and being configurable is the point. Both
# copies are written where they exist: the server owns the effective settings when there is a
# server, and the client needs its own copy for the single-player case.
#
# Usage: 03c-configure-travel-cost.sh <profile>
#   COST_ITEM       item to charge (default casinoCoin)
#   COST_PER_METER  charged per metre (default 0.1)
#   COST_MINIMUM    floor, which is what a short trip actually costs (default 7)
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"

trace_errors

[ $# -eq 1 ] || die "usage: $0 <profile>"
PROFILE="$1"
load_profile "$PROFILE"
require_var CLIENT_MODS_DIR VTT_CLIENT_MOD_DIRNAME

ITEM="${COST_ITEM:-casinoCoin}"
PER_METER="${COST_PER_METER:-0.1}"
MINIMUM="${COST_MINIMUM:-7}"

# A floor rather than a rate is what makes the expected number knowable: the scenario travels
# between two traders standing next to each other, so the distance part rounds to almost
# nothing and the cost is exactly COST_MINIMUM. The rate still has to be above zero - the mod
# treats perMeter <= 0 as "no cost at all" (TravelCostCalculator.CalculateCost).
NEW_LINE="<TravelCost enabled=\"true\" item=\"${ITEM}\" perMeter=\"${PER_METER}\" minimum=\"${MINIMUM}\" />"
log "enabling travel cost: ${ITEM}, ${PER_METER}/m, minimum ${MINIMUM}"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
printf '%s' "$MINIMUM" > "$OUTPUT_DIR/travel-cost-expected.txt"
printf '%s' "$ITEM" > "$OUTPUT_DIR/travel-cost-item.txt"

PATCHED_ANY=0

if [ -n "${SERVER_MODS_DIR:-}" ]; then
    SERVER_CONFIG="${SERVER_MODS_DIR}/VisitedTraderTeleport/Config/VisitedTraderTeleport.xml"
    if [ -f "$SERVER_CONFIG" ]; then
        sed -i -E "s|<TravelCost[^>]*/>|${NEW_LINE}|" "$SERVER_CONFIG"
        grep -qF "$NEW_LINE" "$SERVER_CONFIG" \
            || die "failed to enable travel cost in $SERVER_CONFIG"
        # The mod parses this file as XML and falls back to its defaults if it cannot - which
        # it does quietly, in its own log. Check the shape here instead of finding out later.
        if command -v xmllint >/dev/null 2>&1; then
            xmllint --noout "$SERVER_CONFIG" \
                || die "the rewritten $SERVER_CONFIG is not valid XML"
        fi
        log "patched the server's config"
        PATCHED_ANY=1
    else
        log "no server-side config at $SERVER_CONFIG (hostload run?), skipping"
    fi
fi

CLIENT_CONFIG="${CLIENT_MODS_DIR}\\${VTT_CLIENT_MOD_DIRNAME}\\Config\\VisitedTraderTeleport.xml"
# Through a script file rather than an inline -Command: the attribute quotes did not survive
# ssh -> powershell -Command, the file ended up with `enabled=true` unquoted, and the mod
# answered "Could not read config, using Personal: 'true' is an unexpected token" and ran with
# its defaults. In connect mode the server's copy governs, so the scenario passed anyway and
# only hostload showed it - as "the mod ignores travel cost", which it does not.
CLIENT_RESULT="$(run_on_omen_script "$ROOT_DIR/lib/windows/Set-TravelCost.ps1" \
    -ConfigPath "\"${CLIENT_CONFIG}\"" -Item "$ITEM" -PerMeter "$PER_METER" -Minimum "$MINIMUM" \
    | tr -d '\r' | grep -E '^(PATCHED|MISSING)' | tail -1 || true)"
case "$CLIENT_RESULT" in
    PATCHED*)
        log "patched the client's config: ${CLIENT_RESULT#PATCHED }"
        PATCHED_ANY=1
        ;;
    MISSING)
        die "no client-side config at ${CLIENT_CONFIG} - was the mod deployed?"
        ;;
    *)
        die "could not patch the client's config at ${CLIENT_CONFIG} (got '${CLIENT_RESULT}')"
        ;;
esac

[ "$PATCHED_ANY" = "1" ] || die "travel cost was not enabled anywhere"
log "travel cost configured"
