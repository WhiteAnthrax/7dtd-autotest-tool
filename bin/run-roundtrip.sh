#!/usr/bin/env bash
# Runs the full SdtdTestPilot + vtttest roundtrip: start the server, build+deploy Debug
# mods, launch the client, run the test scenario, verify against server-side data, then
# always tear down (even on failure).
# Usage: run-roundtrip.sh --profile <v3|v26>
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

usage() {
    cat <<EOF
Usage: $0 --profile <v3|v26>

Runs the full record/list/teleport roundtrip against the given profile's Docker server
and Windows client, then tears everything back down (even on failure).
EOF
}

PROFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done
[ -n "$PROFILE" ] || { usage; die "--profile is required"; }

cleanup() {
    local exit_code=$?
    log "running teardown (exit code so far: $exit_code)..."
    "$BIN_DIR/07-teardown.sh" "$PROFILE" || true
    exit "$exit_code"
}
trap cleanup EXIT

STEP_STATUS="unknown"
"$BIN_DIR/01-start-server.sh" "$PROFILE" || STEP_STATUS="start-server failed"
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/02-build-mods.sh" "$PROFILE" || STEP_STATUS="build-mods failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/03-deploy-mods.sh" "$PROFILE" || STEP_STATUS="deploy-mods failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/04-launch-client.sh" "$PROFILE" || STEP_STATUS="launch-client failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/05-run-scenario.sh" "$PROFILE" || STEP_STATUS="run-scenario failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/06-verify.sh" "$PROFILE" || STEP_STATUS="verify failed"
fi
[ "$STEP_STATUS" = "unknown" ] && STEP_STATUS="ok"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
VERIFY_JSON="null"
[ -f "$OUTPUT_DIR/verify-result.json" ] && VERIFY_JSON="$(cat "$OUTPUT_DIR/verify-result.json")"

if command -v jq >/dev/null 2>&1; then
    SUMMARY="$(jq -n --arg profile "$PROFILE" --arg status "$STEP_STATUS" --argjson verify "$VERIFY_JSON" \
        '{profile: $profile, status: $status, verify: $verify}')"
else
    SUMMARY="{\"profile\":\"$PROFILE\",\"status\":\"$STEP_STATUS\"}"
fi
echo "ROUNDTRIP_RESULT $SUMMARY"

[ "$STEP_STATUS" = "ok" ]
