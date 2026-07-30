#!/usr/bin/env bash
# Verifies a released VisitedTraderTeleport package - the exact ZIP users download - by
# installing it and walking the real trader dialog in one or more languages.
#
# Why this exists: every other driver here tests a Debug build, because `vtttest` only
# exists when VTT_TEST_HARNESS is defined and the csproj defines it only for
# Configuration=Debug. The shipped Release build has no harness, so until now the artifact
# users actually download was the one thing nothing ever drove. This closes that by driving
# the dialog from SdtdTestPilot instead - a separate mod, still a Debug build, which knows
# nothing about the mod under test and therefore works against any build of it.
#
# What it can and cannot show is worth being clear about:
#   - it CAN show that the shipped binary loads, that its dialog patches apply, and that it
#     renders localized text, with a screenshot per language;
#   - it CANNOT seed destinations (that needs the mod's internals), so paging boundaries
#     stay the Debug sweep's job. Those transfer as long as the packaged Config/ matches
#     what the sweep deployed - which this script also checks, byte for byte.
#
# Usage: run-release-verification.sh --profile <v3|v26> --package <zip> [--languages a,b,c]
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"
# shellcheck source=lib/testpilot-queue.sh
source "$ROOT_DIR/lib/testpilot-queue.sh"
# shellcheck source=lib/client-control.sh
source "$ROOT_DIR/lib/client-control.sh"

ALL_LANGUAGES="english,german,spanish,french,italian,japanese,koreana,polish,brazilian,russian,turkish,schinese,tchinese"

usage() {
    cat <<EOF
Usage: $0 --profile <v3|v26> --package <zip> [--languages a,b,c] [--fresh-save] [--keep-save]

Installs a released VisitedTraderTeleport ZIP on the server and client and walks the real
trader dialog against it, keeping a screenshot per language.

  --profile <name>     Which config/<name>.env to run against.
  --package <zip>      The released package, e.g. dist/VisitedTraderTeleport-0.7.10.zip.
  --languages a,b,c    Comma-separated languages. Default: english.
  --fresh-save         Run against a throwaway save. Recommended: the walkthrough asserts
                       the player is alive, and a persistent save carrying a character an
                       earlier run got killed fails every language.
  --keep-save          With --fresh-save, keep the throwaway save afterwards.

Results land in output/<profile>/:
  screenshots/<language>/*.jpg        what the shipped build drew
  release-dialog-<language>.json      the dialog dumps for that language
  release-verify-<language>.json      the assertions for that language
  release-verification-result.json    every language, plus the overall verdict
EOF
}

PROFILE=""
PACKAGE=""
LANGUAGES_CSV="english"
FRESH_SAVE=0
KEEP_SAVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --package) PACKAGE="${2:-}"; shift 2 ;;
        --languages) LANGUAGES_CSV="${2:-}"; shift 2 ;;
        --fresh-save) FRESH_SAVE=1; shift ;;
        --keep-save) KEEP_SAVE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$PROFILE" ] || { usage; die "--profile is required"; }
[ -n "$PACKAGE" ] || { usage; die "--package is required"; }
[ -f "$PACKAGE" ] || die "package not found: $PACKAGE"
[ -n "$LANGUAGES_CSV" ] || die "--languages must not be empty"
require_cmd jq grep unzip

IFS=',' read -r -a LANGUAGES <<< "$LANGUAGES_CSV"
for lang in "${LANGUAGES[@]}"; do
    case ",${ALL_LANGUAGES}," in
        *",${lang},"*) ;;
        *) die "unknown language '${lang}'; expected one of ${ALL_LANGUAGES}" ;;
    esac
done

PACKAGE="$(cd "$(dirname "$PACKAGE")" && pwd)/$(basename "$PACKAGE")"
export VTT_RELEASE_PACKAGE="$PACKAGE"
if [ "$KEEP_SAVE" = "1" ] && [ "$FRESH_SAVE" = "0" ]; then
    die "--keep-save only makes sense together with --fresh-save"
fi
export TESTPILOT_FRESH_SAVE="$FRESH_SAVE"
export TESTPILOT_KEEP_SAVE="$KEEP_SAVE"

load_profile "$PROFILE"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/release-verification-result.json"
rm -f "$RESULT_FILE" "$OUTPUT_DIR"/release-dialog-*.json "$OUTPUT_DIR"/release-verify-*.json
rm -rf "$OUTPUT_DIR/screenshots"

cleanup() {
    local exit_code=$?
    log "running teardown (exit code so far: $exit_code)..."
    "$BIN_DIR/07-teardown.sh" "$PROFILE" || true
    exit "$exit_code"
}
trap cleanup EXIT

# See run-language-sweep.sh for why 03 and the world-safety commands are where they are.
make_world_safe() {
    local out
    for cmd in "killall" "settime day"; do
        out="$(submit_and_check "$cmd" | jq -r '.output' | head -2 | tr '\n' ' ' || true)"
        log "world-safety: ${cmd} -> ${out:-<no output>}"
    done
}

STEP_STATUS="unknown"
"$BIN_DIR/01-start-server.sh" "$PROFILE" || STEP_STATUS="start-server failed"
# 02 still runs: SdtdTestPilot is the driver and has to match the game flavour. The mod
# under test comes from the package, not from this build (03 picks it up via
# VTT_RELEASE_PACKAGE).
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/02-build-mods.sh" "$PROFILE" || STEP_STATUS="build-mods failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/03-deploy-mods.sh" "$PROFILE" || STEP_STATUS="deploy-mods failed"
fi

# The packaged Config/ is what carries the Debug sweep's result over to the release: the
# translations live entirely in those files and the DLL only looks keys up. Comparing them
# is cheap and it is the difference between "the same commit" and "the same bytes".
CONFIG_MATCH="not compared"
if [ "$STEP_STATUS" = "unknown" ] && [ -d "$OUTPUT_DIR/mod-config" ] && [ -d "$OUTPUT_DIR/release-mod/VisitedTraderTeleport/Config" ]; then
    if diff -r "$OUTPUT_DIR/mod-config" "$OUTPUT_DIR/release-mod/VisitedTraderTeleport/Config" >/dev/null 2>&1; then
        CONFIG_MATCH="identical"
        log "packaged Config/ is byte-identical to the build from $VTT_BRANCH"
    else
        CONFIG_MATCH="differs"
        log "warn: packaged Config/ differs from the build from $VTT_BRANCH - the sweep's result does not carry over"
        diff -r "$OUTPUT_DIR/mod-config" "$OUTPUT_DIR/release-mod/VisitedTraderTeleport/Config" || true
    fi
fi

RESULTS_JSON="[]"
if [ "$STEP_STATUS" = "unknown" ]; then
    STEP_STATUS="ok"
    FIRST=1
    for lang in "${LANGUAGES[@]}"; do
        log "=== language: ${lang} ==="
        [ "$FIRST" = "1" ] || stop_client
        FIRST=0

        LANG_STATUS="ok"
        if ! CLIENT_LANGUAGE="$lang" "$BIN_DIR/04-launch-client.sh" "$PROFILE"; then
            LANG_STATUS="launch-client failed"
        fi
        [ "$LANG_STATUS" = "ok" ] && make_world_safe
        if [ "$LANG_STATUS" = "ok" ] && ! CLIENT_LANGUAGE="$lang" "$BIN_DIR/05r-run-release-dialog-scenario.sh" "$PROFILE"; then
            LANG_STATUS="run-release-dialog-scenario failed"
        fi
        if [ "$LANG_STATUS" = "ok" ] && ! "$BIN_DIR/06r-verify-release.sh" "$PROFILE"; then
            LANG_STATUS="verify failed"
        fi

        [ -f "$OUTPUT_DIR/release-dialog-result.json" ] && cp "$OUTPUT_DIR/release-dialog-result.json" "$OUTPUT_DIR/release-dialog-${lang}.json"
        [ -f "$OUTPUT_DIR/release-verify-result.json" ] && cp "$OUTPUT_DIR/release-verify-result.json" "$OUTPUT_DIR/release-verify-${lang}.json"

        LANG_VERIFY="null"
        [ -f "$OUTPUT_DIR/release-verify-${lang}.json" ] && LANG_VERIFY="$(cat "$OUTPUT_DIR/release-verify-${lang}.json")"
        RESULTS_JSON="$(jq -n --argjson acc "$RESULTS_JSON" --arg language "$lang" \
            --arg status "$LANG_STATUS" --argjson verify "$LANG_VERIFY" \
            '$acc + [{
                language: $language,
                status: $status,
                ok: ($status == "ok" and ($verify.ok // false)),
                active_language: ($verify.language // null),
                destinations: ($verify.destinations // null),
                unresolved_keys: ($verify.unresolved_keys // null),
                screenshot_dir: ($verify.screenshot_dir // null)
            }]')"

        [ "$LANG_STATUS" = "ok" ] || log "language '${lang}' FAILED: ${LANG_STATUS}"
        rm -f "$OUTPUT_DIR/release-dialog-result.json" "$OUTPUT_DIR/release-verify-result.json"
    done
fi

RUN_OK=false
if [ "$STEP_STATUS" = "ok" ] && [ "$CONFIG_MATCH" = "identical" ] && \
   [ "$(printf '%s' "$RESULTS_JSON" | jq '[.[] | select(.ok | not)] | length')" = "0" ] && \
   [ "$(printf '%s' "$RESULTS_JSON" | jq 'length')" != "0" ]; then
    RUN_OK=true
fi

jq -n --arg profile "$PROFILE" --arg package "$(basename "$PACKAGE")" --arg status "$STEP_STATUS" \
    --arg config_match "$CONFIG_MATCH" --argjson languages "$RESULTS_JSON" --argjson ok "$RUN_OK" \
    '{profile: $profile, package: $package, status: $status, packaged_config: $config_match,
      ok: $ok, languages: $languages}' > "$RESULT_FILE"

echo "RELEASE_VERIFICATION_RESULT $(jq -c '{profile, package, status, packaged_config, ok, failed: [.languages[] | select(.ok | not) | .language]}' "$RESULT_FILE")"

[ "$RUN_OK" = "true" ]
