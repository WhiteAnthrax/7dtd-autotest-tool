#!/usr/bin/env bash
# Runs the trader dialog walkthrough once per UI language and keeps the screenshots.
#
# Same shape as run-roundtrip.sh - start the server, build+deploy, tear down at the end -
# except that the client half is repeated for each language. The game fixes its language
# at startup (Localization.RequestedLanguage reads the `-language=` launch argument once),
# so switching means relaunching, which is why this is a separate driver rather than a
# flag on run-roundtrip.sh.
#
# What repeats and what does not is deliberate:
#
#   - 01/02/03 run once. 03-deploy-mods.sh is not re-runnable inside a single sweep: it
#     re-takes the "original" backups every time it runs, so a second pass would back up
#     the Debug build it deployed on the first pass and the already-reset visit history,
#     and teardown would then faithfully restore those.
#   - 05-run-scenario.sh also runs once. It spawns traders at the player's current
#     position and teleports to one of them, and it relies on 03 having reset the visit
#     history so that at most one destination exists per trader. Running it again with
#     history already present breaks that assumption, and picking the wrong destination
#     to teleport to is how a test run gets the player killed (see docs/lessons-learned.md).
#   - 05b + 06 repeat per language. The dialog walkthrough only opens a dialog and seeds
#     synthetic destinations client-side; it never teleports, so repeating it is safe.
#
# Usage: run-language-sweep.sh --profile <v3|v26> [--languages a,b,c]
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

# Every language 7DTD ships, named the way the game names them - these are the column
# names in Localization.csv and the values `-language=` accepts.
ALL_LANGUAGES="english,german,spanish,french,italian,japanese,koreana,polish,brazilian,russian,turkish,schinese,tchinese"

usage() {
    cat <<EOF
Usage: $0 --profile <v3|v26> [--languages a,b,c]

Walks the trader dialog once per UI language and keeps a screenshot of every step, so a
localization change can be checked for clipped or untranslated text.

  --profile <name>     Which config/<name>.env to run against.
  --languages a,b,c    Comma-separated languages to sweep, in order. Default: all of
                       ${ALL_LANGUAGES}.

Results land in output/<profile>/:
  screenshots/<language>/*.jpg   what the client drew, per language
  dialog-<language>.json         the dialog dumps for that language
  verify-<language>.json         the assertions for that language
  language-sweep-result.json     one entry per language, plus the overall verdict

Budget roughly three minutes per language on top of a two-and-a-half minute setup.
EOF
}

PROFILE=""
LANGUAGES_CSV="$ALL_LANGUAGES"
while [ $# -gt 0 ]; do
    case "$1" in
        --profile)
            PROFILE="${2:-}"
            shift 2
            ;;
        --languages)
            LANGUAGES_CSV="${2:-}"
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
[ -n "$LANGUAGES_CSV" ] || die "--languages must not be empty"
require_cmd jq grep

IFS=',' read -r -a LANGUAGES <<< "$LANGUAGES_CSV"
for lang in "${LANGUAGES[@]}"; do
    case ",${ALL_LANGUAGES}," in
        *",${lang},"*) ;;
        *) die "unknown language '${lang}'; expected one of ${ALL_LANGUAGES}" ;;
    esac
done

# The sweep reuses the profile's persistent save, the same as an ordinary roundtrip.
export TESTPILOT_FRESH_SAVE=0
export TESTPILOT_KEEP_SAVE=0

load_profile "$PROFILE"

OUTPUT_DIR="$ROOT_DIR/output/$PROFILE"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/language-sweep-result.json"
# Drop the previous sweep's per-language files before starting. Leaving them would let a
# language that failed early this time still show last sweep's green result.
rm -f "$RESULT_FILE" "$OUTPUT_DIR"/dialog-*.json "$OUTPUT_DIR"/verify-*.json
rm -rf "$OUTPUT_DIR/screenshots"

cleanup() {
    local exit_code=$?
    log "running teardown (exit code so far: $exit_code)..."
    "$BIN_DIR/07-teardown.sh" "$PROFILE" || true
    exit "$exit_code"
}
trap cleanup EXIT

# resolve_trader_id: entity id of a live npcTraderBob, spawning one next to the player if
# the previous client session's trader is gone. Spawning here is safe in a way that
# re-running 05 is not: the trader appears where the player already stands, so it
# canonicalizes into the destination that is already recorded there, and nothing in the
# dialog walkthrough teleports anywhere.
resolve_trader_id() {
    local le_output id player_id
    le_output="$(submit_and_check "le" | jq -r '.output')"
    id="$(printf '%s' "$le_output" | grep -oP 'name=npcTraderBob, id=\K[0-9]+' | head -1 || true)"
    if [ -n "$id" ]; then
        printf '%s' "$id"
        return 0
    fi

    player_id="$(printf '%s' "$le_output" | grep -oP 'EntityPlayerLocal.*?id=\K[0-9]+' | head -1 || true)"
    [ -n "$player_id" ] || return 1
    log "no live npcTraderBob; spawning one next to player id=${player_id}"
    submit_and_check "se ${player_id} npcTraderBob 1" >/dev/null
    le_output="$(submit_and_check "le" | jq -r '.output')"
    id="$(printf '%s' "$le_output" | grep -oP 'name=npcTraderBob, id=\K[0-9]+' | head -1 || true)"
    [ -n "$id" ] || return 1
    printf '%s' "$id"
}

STEP_STATUS="unknown"
"$BIN_DIR/01-start-server.sh" "$PROFILE" || STEP_STATUS="start-server failed"
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/02-build-mods.sh" "$PROFILE" || STEP_STATUS="build-mods failed"
fi
if [ "$STEP_STATUS" = "unknown" ]; then
    "$BIN_DIR/03-deploy-mods.sh" "$PROFILE" || STEP_STATUS="deploy-mods failed"
fi

RESULTS_JSON="[]"
if [ "$STEP_STATUS" = "unknown" ]; then
    STEP_STATUS="ok"
    SCENARIO_DONE=0
    for lang in "${LANGUAGES[@]}"; do
        log "=== language: ${lang} ==="

        # The client is still running in the previous language, and the language cannot
        # change without a restart.
        [ "$SCENARIO_DONE" = "1" ] && stop_client

        LANG_STATUS="ok"
        if ! CLIENT_LANGUAGE="$lang" "$BIN_DIR/04-launch-client.sh" "$PROFILE"; then
            LANG_STATUS="launch-client failed"
        fi

        if [ "$LANG_STATUS" = "ok" ] && [ "$SCENARIO_DONE" = "0" ]; then
            if "$BIN_DIR/05-run-scenario.sh" "$PROFILE"; then
                SCENARIO_DONE=1
            else
                LANG_STATUS="run-scenario failed"
            fi
        fi

        TRADER_ID=""
        if [ "$LANG_STATUS" = "ok" ]; then
            TRADER_ID="$(resolve_trader_id || true)"
            [ -n "$TRADER_ID" ] || LANG_STATUS="could not resolve a live npcTraderBob"
        fi

        if [ "$LANG_STATUS" = "ok" ]; then
            if ! CLIENT_LANGUAGE="$lang" VTT_DIALOG_TRADER_ID="$TRADER_ID" \
                "$BIN_DIR/05b-run-dialog-scenario.sh" "$PROFILE"; then
                LANG_STATUS="run-dialog-scenario failed"
            fi
        fi
        if [ "$LANG_STATUS" = "ok" ] && ! "$BIN_DIR/06-verify.sh" "$PROFILE"; then
            LANG_STATUS="verify failed"
        fi

        # Keep this language's evidence under its own name before the next pass overwrites
        # the shared files. The screenshots already live in a per-language directory.
        [ -f "$OUTPUT_DIR/dialog-result.json" ] && cp "$OUTPUT_DIR/dialog-result.json" "$OUTPUT_DIR/dialog-${lang}.json"
        [ -f "$OUTPUT_DIR/verify-result.json" ] && cp "$OUTPUT_DIR/verify-result.json" "$OUTPUT_DIR/verify-${lang}.json"

        LANG_VERIFY="null"
        [ -f "$OUTPUT_DIR/verify-${lang}.json" ] && LANG_VERIFY="$(cat "$OUTPUT_DIR/verify-${lang}.json")"
        RESULTS_JSON="$(jq -n --argjson acc "$RESULTS_JSON" --arg language "$lang" \
            --arg status "$LANG_STATUS" --argjson verify "$LANG_VERIFY" \
            '$acc + [{
                language: $language,
                status: $status,
                ok: ($status == "ok" and ($verify.ok // false)),
                active_language: ($verify.dialog.language // null),
                language_as_requested: ($verify.dialog.language_as_requested // null),
                unresolved_keys: ($verify.dialog.unresolved_keys // null),
                screenshot_dir: ($verify.dialog.screenshot_dir // null)
            }]')"

        [ "$LANG_STATUS" = "ok" ] || log "language '${lang}' FAILED: ${LANG_STATUS}"

        # Deliberately keep going after a failed language: knowing which languages are
        # broken is worth far more than stopping at the first one, and the passes after it
        # cost the same either way.
        rm -f "$OUTPUT_DIR/dialog-result.json" "$OUTPUT_DIR/verify-result.json"
    done
fi

SWEEP_OK=false
if [ "$STEP_STATUS" = "ok" ] && \
   [ "$(printf '%s' "$RESULTS_JSON" | jq '[.[] | select(.ok | not)] | length')" = "0" ] && \
   [ "$(printf '%s' "$RESULTS_JSON" | jq 'length')" != "0" ]; then
    SWEEP_OK=true
fi

jq -n --arg profile "$PROFILE" --arg status "$STEP_STATUS" \
    --argjson languages "$RESULTS_JSON" --argjson ok "$SWEEP_OK" \
    '{profile: $profile, status: $status, ok: $ok, languages: $languages}' > "$RESULT_FILE"

echo "LANGUAGE_SWEEP_RESULT $(jq -c '{profile, status, ok, failed: [.languages[] | select(.ok | not) | .language]}' "$RESULT_FILE")"

[ "$SWEEP_OK" = "true" ]
