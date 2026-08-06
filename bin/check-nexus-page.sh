#!/usr/bin/env bash
# Reads a Nexus mod page back through the API and says whether it looks the way a released
# page should.
#
# The August 2026 release published correctly and still left the page wrong: the previous
# v2.6 build stayed in Optional files next to the new one, because it had been uploaded as a
# separate file entry rather than as a version of the same file, and Nexus only moves the
# previous version of the *same* file out of the way. Nobody noticed until the page was
# looked at by eye.
#
# What it checks, per file on the page:
#   - exactly one version is current (anything not old_version / archived counts as current)
#   - the newest version is the current one
# and across the page:
#   - no two files claim the same category, which is the shape of the problem above
#
# It cannot fix anything: the Upload API archives the previous version of the file being
# uploaded (publish-to-nexus.sh --archive-existing) and offers nothing for a different file.
# Tidying that up is a click on the site, so this points at it rather than pretending.
#
# Usage: check-nexus-page.sh --mod-id <id> [--quiet]
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

NEXUS_ENV_FILE="${NEXUS_ENV_FILE:-$HOME/.config/nexus-upload.env}"
API_BASE="${NEXUS_API_BASE:-https://api.nexusmods.com/v3}"

usage() {
    cat <<EOF
Usage: $0 --mod-id <id> [--quiet]

  --mod-id <id>   The API's mod id (not the number in the page URL).
  --quiet         Only complain; say nothing when the page is fine.

Exits non-zero when something on the page needs attention.
EOF
}

MOD_ID=""
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --mod-id) MOD_ID="${2:-}"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
done
[ -n "$MOD_ID" ] || { usage; die "--mod-id is required"; }
require_cmd curl jq

if [ -z "${NEXUS_API_KEY:-}" ] && [ -f "$NEXUS_ENV_FILE" ]; then
    # shellcheck disable=SC1090 # path is configurable and lives outside the repo on purpose
    source "$NEXUS_ENV_FILE"
fi
[ -n "${NEXUS_API_KEY:-}" ] || die "NEXUS_API_KEY is not set and $NEXUS_ENV_FILE has no key"

nexus_get() {
    curl -sS -H "apikey: ${NEXUS_API_KEY}" -H "User-Agent: 7dtd-autotest-tool" "${API_BASE}$1"
}

FILES_JSON="$(nexus_get "/mods/${MOD_ID}/files")" || die "could not list the mod's files"
FILE_IDS="$(printf '%s' "$FILES_JSON" | jq -r '.data.mod_files[]?.id // empty')"
[ -n "$FILE_IDS" ] || die "the API returned no files for mod ${MOD_ID}"

PROBLEMS=0
SUMMARY=""
CURRENT_CATEGORIES=""

for file_id in $FILE_IDS; do
    VERSIONS_JSON="$(nexus_get "/mod-files/${file_id}/versions")" || die "could not read versions for file ${file_id}"
    # "Current" is anything the page still presents as a live download. Nexus has several
    # labels for the opposite (old_version, archived); treat every one of them as retired
    # rather than listing the live ones, so a new label does not read as "current" by
    # accident.
    CURRENT="$(printf '%s' "$VERSIONS_JSON" \
        | jq -c '[.data.versions[] | select((.category // "") | test("old_version|archived") | not)]')"
    CURRENT_COUNT="$(printf '%s' "$CURRENT" | jq 'length')"
    NEWEST="$(printf '%s' "$VERSIONS_JSON" | jq -r '.data.versions[0].version // "?"')"
    NEWEST_CATEGORY="$(printf '%s' "$VERSIONS_JSON" | jq -r '.data.versions[0].category // "?"')"
    CURRENT_LIST="$(printf '%s' "$CURRENT" | jq -r '[.[] | "\(.version) (\(.category))"] | join(", ")')"

    SUMMARY="${SUMMARY}  file ${file_id}: newest ${NEWEST} [${NEWEST_CATEGORY}], current: ${CURRENT_LIST:-none}"$'\n'

    if [ "$CURRENT_COUNT" -gt 1 ]; then
        SUMMARY="${SUMMARY}    -> ${CURRENT_COUNT} versions of this file are still listed as current"$'\n'
        PROBLEMS=$((PROBLEMS + 1))
    fi
    if [ "$CURRENT_COUNT" -ge 1 ] && printf '%s' "$NEWEST_CATEGORY" | grep -qE "old_version|archived"; then
        SUMMARY="${SUMMARY}    -> the newest version is retired while an older one is still current"$'\n'
        PROBLEMS=$((PROBLEMS + 1))
    fi
    if [ "$CURRENT_COUNT" = "1" ]; then
        CURRENT_CATEGORIES="${CURRENT_CATEGORIES}$(printf '%s' "$CURRENT" | jq -r '.[0].category')|${file_id}"$'\n'
    fi
done

# Two files in the same category is what the leftover 0.6.22 looked like from here: both
# "optional", both current, and the page showing the old build next to the new one.
DUPLICATE_CATEGORIES="$(printf '%s' "$CURRENT_CATEGORIES" | grep -v '^$' | cut -d'|' -f1 | sort | uniq -d || true)"
if [ -n "$DUPLICATE_CATEGORIES" ]; then
    while IFS= read -r category; do
        [ -n "$category" ] || continue
        IDS="$(printf '%s' "$CURRENT_CATEGORIES" | grep "^${category}|" | cut -d'|' -f2 | tr '\n' ' ')"
        SUMMARY="${SUMMARY}  -> more than one file is current in category '${category}': ${IDS}"$'\n'
        SUMMARY="${SUMMARY}     the older one probably belongs in Old files (Files step -> the file's menu -> Archive)"$'\n'
        PROBLEMS=$((PROBLEMS + 1))
    done <<< "$DUPLICATE_CATEGORIES"
fi

if [ "$PROBLEMS" = "0" ]; then
    if [ "$QUIET" != "1" ]; then
        log "the page looks clean:"
        printf '%s' "$SUMMARY"
    fi
    exit 0
fi

log "the page needs attention (${PROBLEMS} thing(s)):"
printf '%s' "$SUMMARY"
exit 1
