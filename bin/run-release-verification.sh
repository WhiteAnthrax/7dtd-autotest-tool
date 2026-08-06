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
# shellcheck source=lib/docker-server.sh
source "$ROOT_DIR/lib/docker-server.sh"

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

hold_profile_lock "$PROFILE"
hold_dedicated_server_lock
OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/release-verification-result.json"
# Every verdict this run will write, dropped first: a run that dies half way through must not
# be able to present the previous run's answer for the stage it never reached.
rm -f "$RESULT_FILE" "$OUTPUT_DIR"/release-dialog-*.json "$OUTPUT_DIR"/release-verify-*.json \
    "$OUTPUT_DIR/release-travel-result.json" "$OUTPUT_DIR/release-travel-verify.json" \
    "$OUTPUT_DIR/companion-result.json" "$OUTPUT_DIR/companion-verify.json" \
    "$OUTPUT_DIR/distance-travel-result.json" "$OUTPUT_DIR/distance-travel-verify.json" \
    "$OUTPUT_DIR/paging-result.json" "$OUTPUT_DIR/paging-verify.json" \
    "$OUTPUT_DIR/travel-cost-result.json" "$OUTPUT_DIR/travel-cost-verify.json"
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

# --- what it does, rather than what it renders ----------------------------------------
#
# These run once each, after the languages, rather than on the first language. They check
# behaviour, so repeating them per language would only re-prove the same thing - and two of
# them change the world in ways the rendering checks would notice: paging records seven
# destinations and distance leaves a trader a kilometre away, either of which would change
# what the next language's dialog shows.
#
# All of them are part of the gate. A release that only proves the dialog renders is how the
# companion bug (#21) reached users in the first place.
#
# Only the dedicated-server topology is covered here, because that is what this script
# starts. The single-player path is a different branch of the mod and needs its own runs:
#   ./bin/run-scenario-check.sh --scenario <name> --profile <p> --mode hostload --package <zip>
BEHAVIOUR_JSON="{}"
run_behaviour_stage() {
    local name="$1" scenario="$2" verify="$3" verdict_file="$4" verdict="null" status="ok"

    if [ "$STEP_STATUS" != "ok" ]; then
        return
    fi

    log "=== ${name} ==="
    if ! "$BIN_DIR/$scenario" "$PROFILE"; then
        status="scenario failed"
    elif ! "$BIN_DIR/$verify" "$PROFILE"; then
        status="verification failed"
    fi
    [ -f "$OUTPUT_DIR/$verdict_file" ] && verdict="$(cat "$OUTPUT_DIR/$verdict_file")"
    BEHAVIOUR_JSON="$(jq -n --argjson acc "$BEHAVIOUR_JSON" --arg name "$name" \
        --arg status "$status" --argjson verdict "$verdict" \
        '$acc + {($name): {status: $status, ok: ($status == "ok" and ($verdict.ok // false)), verdict: $verdict}}')"
    if [ "$status" != "ok" ]; then
        log "${name} FAILED: ${status}"
        STEP_STATUS="${name} ${status}"
    fi
}

run_behaviour_stage travel 05t-run-release-travel-scenario.sh 06t-verify-release-travel.sh release-travel-verify.json
run_behaviour_stage companions 05c-run-companion-scenario.sh 06c-verify-companions.sh companion-verify.json
run_behaviour_stage distance 05d-run-distance-travel-scenario.sh 06d-verify-distance-travel.sh distance-travel-verify.json
run_behaviour_stage paging 05p-run-paging-scenario.sh 06p-verify-paging.sh paging-verify.json

# Travel cost last, and on a restarted world: the mod reads its config when the world loads
# and has no reload, so the setting has to be in place before the client (and the server, when
# there is one) start. Leaving it enabled for the earlier stages would change them - a paid
# trip asks for confirmation, and a player with nothing to pay with does not travel at all.
if [ "$STEP_STATUS" = "ok" ]; then
    log "=== travel cost (restarting with the cost setting on) ==="
    stop_client
    if ! "$BIN_DIR/03c-configure-travel-cost.sh" "$PROFILE"; then
        STEP_STATUS="travel cost configuration failed"
    elif ! docker_server_restart || ! docker_server_wait_started 480; then
        STEP_STATUS="server restart for the travel cost stage failed"
    elif ! "$BIN_DIR/04-launch-client.sh" "$PROFILE"; then
        STEP_STATUS="relaunch for the travel cost stage failed"
    else
        make_world_safe
    fi
    run_behaviour_stage cost 05x-run-travel-cost-scenario.sh 06x-verify-travel-cost.sh travel-cost-verify.json
fi

# Every stage ran and every stage passed. Written with the "did any stage run" test first,
# because the obvious phrasing - filter to the failures, then ask for the length twice - asks
# the second question of the *filtered* list: with nothing failing that list is empty, so
# "more than zero stages" was false and a run where everything passed reported ok:false.
BEHAVIOUR_OK="$(printf '%s' "$BEHAVIOUR_JSON" \
    | jq '(length > 0) and ([.[] | select(.ok | not)] | length == 0)' 2>/dev/null || printf 'false')"

RUN_OK=false
if [ "$STEP_STATUS" = "ok" ] && [ "$CONFIG_MATCH" = "identical" ] && [ "$BEHAVIOUR_OK" = "true" ] && \
   [ "$(printf '%s' "$RESULTS_JSON" | jq '[.[] | select(.ok | not)] | length')" = "0" ] && \
   [ "$(printf '%s' "$RESULTS_JSON" | jq 'length')" != "0" ]; then
    RUN_OK=true
fi

# The hash, not just the name: a rebuilt ZIP keeps its version number, so recording only
# the file name let a fresh build inherit an older build's green result. bin/publish-to-nexus.sh
# compares this against the file it is about to upload.
PACKAGE_SHA="$(sha256sum "$PACKAGE" | cut -d' ' -f1)"

# Which commit the ZIP was built from, when bin/build-release-package.sh made it. The sidecar
# is checked against the file rather than trusted: a provenance naming a different build is
# worse than none, so a mismatch drops it instead of recording a comfortable-looking lie.
PROVENANCE="null"
if [ -f "${PACKAGE}.provenance.json" ]; then
    if [ "$(jq -r '.sha256 // ""' "${PACKAGE}.provenance.json")" = "$PACKAGE_SHA" ]; then
        PROVENANCE="$(jq -c '{source_commit, ref, commit_subject}' "${PACKAGE}.provenance.json")"
        log "built from $(jq -r '.ref' "${PACKAGE}.provenance.json") @ $(jq -r '.source_commit[0:12]' "${PACKAGE}.provenance.json")"
    else
        log "warn: ${PACKAGE}.provenance.json describes a different build of this ZIP, ignoring it"
    fi
else
    log "warn: no provenance sidecar - this package was not built by bin/build-release-package.sh, so which commit it came from is not recorded"
fi

jq -n --arg profile "$PROFILE" --arg package "$(basename "$PACKAGE")" --arg status "$STEP_STATUS" \
    --arg sha256 "$PACKAGE_SHA" --argjson provenance "$PROVENANCE" \
    --arg config_match "$CONFIG_MATCH" --argjson languages "$RESULTS_JSON" --argjson ok "$RUN_OK" \
    --argjson behaviour "$BEHAVIOUR_JSON" \
    '{profile: $profile, package: $package, sha256: $sha256, built_from: $provenance,
      status: $status, packaged_config: $config_match,
      ok: $ok, behaviour: $behaviour, languages: $languages}' > "$RESULT_FILE"

echo "RELEASE_VERIFICATION_RESULT $(jq -c '{profile, package, sha256, built_from, status, packaged_config, ok,
        failed: ([.languages[] | select(.ok | not) | .language]
                 + [.behaviour | to_entries[] | select(.value.ok | not) | .key])}' "$RESULT_FILE")"

[ "$RUN_OK" = "true" ]
