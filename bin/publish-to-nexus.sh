#!/usr/bin/env bash
# Uploads a verified release package to an existing Nexus Mods file, and posts its changelog.
#
# The gate is the point: it refuses to upload unless run-release-verification.sh has passed
# against this exact ZIP. Publishing before verifying is how a release once went out with
# only its Debug twin ever having been run - see docs/lessons-learned.md.
#
# Protocol is the Nexus Mods v3 Upload API, read off Nexus-Mods/upload-action (their own
# GitHub Action) rather than guessed:
#   1. POST /uploads/multipart          -> upload id, presigned part URLs, part size
#   2. PUT  <presigned part URL>        -> one per part, ETag comes back in the header
#   3. POST <complete presigned URL>    -> XML listing every part number + ETag
#   4. POST /uploads/{id}/finalise
#   5. GET  /uploads/{id}               -> poll until state == "available"
#   6. POST /mod-files/{fileId}/versions
#   7. POST /mods/{modId}/changelogs    -> optional, needs the mod id
#
# The presigned URLs are S3 and must NOT carry the API key header; only api.nexusmods.com
# calls are authenticated.
#
# Creating a new mod page is not part of this API - it only adds a version to a file that
# already exists on the page.
#
# Usage: publish-to-nexus.sh --profile <v3|v26> --package <zip> --version <x.y.z>
#                            --file-id <id> [--mod-id <id>] [--changelog <file>]
#                            [--display-name <name>] [--category main|optional|miscellaneous]
#                            [--archive-existing] [--update-mod-version] [--dry-run] [--yes]
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

API_BASE="${NEXUSMODS_API_BASE:-https://api.nexusmods.com/v3}"
# Kept outside the repo, like every other credential here. Mode 600, holds NEXUS_API_KEY=...
NEXUS_ENV_FILE="${NEXUS_ENV_FILE:-$HOME/.config/nexus-upload.env}"

usage() {
    cat <<EOF
Usage: $0 --profile <v3|v26> --package <zip> --version <x.y.z> --file-id <id> [options]

Uploads a release package to an existing Nexus Mods file and posts its changelog.
Refuses to upload unless run-release-verification.sh passed against this exact ZIP.

  --profile <name>        Which config/<name>.env the verification result belongs to.
  --package <zip>         The package to upload.
  --version <x.y.z>       Version string shown on Nexus.
  --file-id <id>          Existing Nexus file id to add this version to.
  --mod-id <id>           Mod id. Required to post a changelog.
  --changelog <file>      Changelog text file, e.g. docs/NexusModsChangelog-0.7.10.txt.
                          Its first line is dropped if it is just the version number.
  --display-name <name>   File name shown on Nexus. Default: the ZIP's basename.
  --category <c>          main (default), optional, or miscellaneous.
  --archive-existing      Archive the file's current version.
  --previous-version-id   The version this one replaces. Found automatically by default.
  --no-supersede          Do not tell Nexus which version this one replaces.
  --update-mod-version    Also set the mod page's version to --version.
  --dry-run               Print what would be sent and stop before the first upload call.
  --yes                   Skip the confirmation prompt.

The API key is read from NEXUS_API_KEY, or from \$NEXUS_ENV_FILE (default
~/.config/nexus-upload.env, mode 600). Never pass it on the command line - it would land
in the shell history and in the process list.
EOF
}

PROFILE=""; PACKAGE=""; VERSION=""; FILE_ID=""; MOD_ID=""; CHANGELOG_FILE=""
DISPLAY_NAME=""; CATEGORY="main"; ARCHIVE_EXISTING=false; UPDATE_MOD_VERSION=false
SUPERSEDE=1; PREVIOUS_VERSION_ID=""
DRY_RUN=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --package) PACKAGE="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --file-id) FILE_ID="${2:-}"; shift 2 ;;
        --mod-id) MOD_ID="${2:-}"; shift 2 ;;
        --changelog) CHANGELOG_FILE="${2:-}"; shift 2 ;;
        --display-name) DISPLAY_NAME="${2:-}"; shift 2 ;;
        --category) CATEGORY="${2:-}"; shift 2 ;;
        --archive-existing) ARCHIVE_EXISTING=true; shift ;;
        --previous-version-id) PREVIOUS_VERSION_ID="${2:-}"; SUPERSEDE=1; shift 2 ;;
        --no-supersede) SUPERSEDE=0; shift ;;
        --update-mod-version) UPDATE_MOD_VERSION=true; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$PROFILE" ] || { usage; die "--profile is required"; }
[ -n "$PACKAGE" ] || { usage; die "--package is required"; }
[ -n "$VERSION" ] || { usage; die "--version is required"; }
[ -n "$FILE_ID" ] || { usage; die "--file-id is required"; }
[ -f "$PACKAGE" ] || die "package not found: $PACKAGE"
case "$CATEGORY" in
    main|optional|miscellaneous) ;;
    *) die "--category must be main, optional or miscellaneous (got '$CATEGORY')" ;;
esac
if [ -n "$CHANGELOG_FILE" ]; then
    [ -f "$CHANGELOG_FILE" ] || die "changelog file not found: $CHANGELOG_FILE"
    [ -n "$MOD_ID" ] || die "--mod-id is required when --changelog is given"
fi
require_cmd jq curl stat dd base64

PACKAGE_NAME="$(basename "$PACKAGE")"
[ -n "$DISPLAY_NAME" ] || DISPLAY_NAME="$PACKAGE_NAME"

# --- the gate -------------------------------------------------------------------------
# Same bytes AND ok:true. The name alone is not enough and this was not theoretical: both
# packages were rebuilt from a later commit, kept their version numbers, and would have
# sailed through on a verification run two days earlier against different bytes. The sha256
# is what makes "this exact file was verified" a fact rather than a recollection.
VERIFY_FILE="$ROOT_DIR/output/$PROFILE/release-verification-result.json"
[ -f "$VERIFY_FILE" ] || die "missing $VERIFY_FILE - run bin/run-release-verification.sh --profile $PROFILE --package $PACKAGE first"
VERIFIED_PACKAGE="$(jq -r '.package // ""' "$VERIFY_FILE")"
VERIFIED_OK="$(jq -r '.ok // false' "$VERIFY_FILE")"
VERIFIED_CONFIG="$(jq -r '.packaged_config // "?"' "$VERIFY_FILE")"
VERIFIED_SHA="$(jq -r '.sha256 // ""' "$VERIFY_FILE")"
if [ "$VERIFIED_PACKAGE" != "$PACKAGE_NAME" ]; then
    die "the last verification was for '$VERIFIED_PACKAGE', not '$PACKAGE_NAME' - re-run bin/run-release-verification.sh for this package"
fi
PACKAGE_SHA="$(sha256sum "$PACKAGE" | cut -d' ' -f1)"
if [ -z "$VERIFIED_SHA" ]; then
    die "$VERIFY_FILE predates the sha256 check, so it cannot say which build it verified - re-run bin/run-release-verification.sh --profile $PROFILE --package $PACKAGE"
fi
if [ "$VERIFIED_SHA" != "$PACKAGE_SHA" ]; then
    die "'$PACKAGE_NAME' was rebuilt since it was verified (verified ${VERIFIED_SHA:0:12}, about to upload ${PACKAGE_SHA:0:12}) - re-run bin/run-release-verification.sh for this build"
fi
if [ "$VERIFIED_OK" != "true" ]; then
    die "the last verification of '$PACKAGE_NAME' did not pass (see $VERIFY_FILE)"
fi
log "verification ok for $PACKAGE_NAME sha256:${PACKAGE_SHA:0:12} (packaged config: $VERIFIED_CONFIG)"

# --- credentials ----------------------------------------------------------------------
if [ -z "${NEXUS_API_KEY:-}" ] && [ -f "$NEXUS_ENV_FILE" ]; then
    # shellcheck disable=SC1090 # path is configurable and lives outside the repo on purpose
    source "$NEXUS_ENV_FILE"
fi
[ -n "${NEXUS_API_KEY:-}" ] || die "NEXUS_API_KEY is not set and $NEXUS_ENV_FILE has no key (see --help)"

FILE_SIZE="$(stat -c %s "$PACKAGE")"

CHANGELOG_TEXT=""
if [ -n "$CHANGELOG_FILE" ]; then
    # The repo's changelog files start with the bare version number, which Nexus already
    # knows from the version field and would render as a stray first line.
    if [ "$(head -1 "$CHANGELOG_FILE" | tr -d '\r')" = "$VERSION" ]; then
        CHANGELOG_TEXT="$(tail -n +2 "$CHANGELOG_FILE")"
    else
        CHANGELOG_TEXT="$(cat "$CHANGELOG_FILE")"
    fi
fi

cat <<EOF

About to upload to Nexus Mods:
  package          $PACKAGE ($FILE_SIZE bytes)
  display name     $DISPLAY_NAME
  version          $VERSION
  file id          $FILE_ID
  mod id           ${MOD_ID:-<none>}
  category         $CATEGORY
  archive existing $ARCHIVE_EXISTING
  supersede        $([ "$SUPERSEDE" = "1" ] && echo "yes${PREVIOUS_VERSION_ID:+ (${PREVIOUS_VERSION_ID})}" || echo "no")
  set mod version  $UPDATE_MOD_VERSION
  changelog        ${CHANGELOG_FILE:-<none>}
  api base         $API_BASE
EOF
if [ -n "$CHANGELOG_TEXT" ]; then
    printf '\n--- changelog to post ---\n%s\n-------------------------\n' "$CHANGELOG_TEXT"
fi

if [ "$DRY_RUN" = "1" ]; then
    log "dry run: nothing was uploaded"
    exit 0
fi

# Uploading is public and cannot be taken back cleanly, so make it deliberate.
if [ "$ASSUME_YES" != "1" ]; then
    printf '\nProceed? [y/N] '
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) die "aborted" ;;
    esac
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# nexus_api <method> <path> [json body]: an authenticated call to api.nexusmods.com.
# The key goes in a header from a variable, never on the curl command line.
nexus_api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS -X "$method" -H "Content-Type: application/json"
                -H "apikey: ${NEXUS_API_KEY}" -H "User-Agent: 7dtd-autotest-tool"
                -w '\n%{http_code}')
    [ -n "$body" ] && args+=(--data-binary "$body")
    curl "${args[@]}" "${API_BASE}${path}"
}

# check_response <combined body+status> <what>: splits the trailing status code off, dies
# on anything outside 2xx, prints the body.
check_response() {
    local combined="$1" what="$2"
    local status body
    status="$(printf '%s' "$combined" | tail -n1)"
    body="$(printf '%s' "$combined" | sed '$d')"
    case "$status" in
        2*) printf '%s' "$body" ;;
        *) die "${what} failed (HTTP ${status}): ${body}" ;;
    esac
}

log "step 1/7: requesting a multipart upload"
CREATE_BODY="$(jq -n --arg filename "$PACKAGE_NAME" --arg size "$FILE_SIZE" \
    '{filename: $filename, size_bytes: $size}')"
CREATE_JSON="$(check_response "$(nexus_api POST /uploads/multipart "$CREATE_BODY")" "creating the multipart upload")"

UPLOAD_ID="$(printf '%s' "$CREATE_JSON" | jq -r '.data.id')"
PART_SIZE="$(printf '%s' "$CREATE_JSON" | jq -r '.data.part_size_bytes')"
COMPLETE_URL="$(printf '%s' "$CREATE_JSON" | jq -r '.data.complete_presigned_url')"
mapfile -t PART_URLS < <(printf '%s' "$CREATE_JSON" | jq -r '.data.part_presigned_urls[]')
if [ -z "$UPLOAD_ID" ] || [ "${#PART_URLS[@]}" -eq 0 ]; then
    die "unexpected multipart response: $CREATE_JSON"
fi
log "upload id ${UPLOAD_ID}: ${#PART_URLS[@]} part(s) of ${PART_SIZE} bytes"

log "step 2/7: uploading parts"
PARTS_XML="$TMP_DIR/parts.xml"
: > "$PARTS_XML"
part_number=0
for url in "${PART_URLS[@]}"; do
    part_number=$((part_number + 1))
    part_file="$TMP_DIR/part.bin"
    dd if="$PACKAGE" of="$part_file" bs="$PART_SIZE" skip="$((part_number - 1))" count=1 status=none \
        || die "failed to read part ${part_number} out of $PACKAGE"
    # The presigned URL carries its own auth; adding the API key header would break it.
    headers="$TMP_DIR/part.headers"
    status="$(curl -sS -X PUT -D "$headers" -o /dev/null -w '%{http_code}' \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${part_file}" "$url")"
    case "$status" in
        2*) ;;
        *) die "uploading part ${part_number} failed (HTTP ${status})" ;;
    esac
    etag="$(grep -i '^etag:' "$headers" | tail -1 | cut -d' ' -f2- | tr -d '"\r\n')"
    [ -n "$etag" ] || die "no ETag returned for part ${part_number}"
    printf '  <Part>\n    <PartNumber>%s</PartNumber>\n    <ETag>%s</ETag>\n  </Part>\n' \
        "$part_number" "$etag" >> "$PARTS_XML"
    log "  part ${part_number}/${#PART_URLS[@]} uploaded"
done

log "step 3/7: completing the multipart upload"
COMPLETE_XML="$TMP_DIR/complete.xml"
{
    printf '<CompleteMultipartUpload>\n'
    cat "$PARTS_XML"
    printf '</CompleteMultipartUpload>\n'
} > "$COMPLETE_XML"
status="$(curl -sS -X POST -o "$TMP_DIR/complete.out" -w '%{http_code}' \
    -H "Content-Type: application/xml" --data-binary "@${COMPLETE_XML}" "$COMPLETE_URL")"
case "$status" in
    2*) ;;
    *) die "completing the multipart upload failed (HTTP ${status}): $(cat "$TMP_DIR/complete.out")" ;;
esac

log "step 4/7: finalising the upload"
check_response "$(nexus_api POST "/uploads/${UPLOAD_ID}/finalise")" "finalising the upload" >/dev/null

log "step 5/7: waiting for the upload to become available"
STATE=""
for attempt in $(seq 1 60); do
    STATE_JSON="$(check_response "$(nexus_api GET "/uploads/${UPLOAD_ID}")" "reading the upload state")"
    STATE="$(printf '%s' "$STATE_JSON" | jq -r '.data.state')"
    log "  attempt ${attempt}: state = ${STATE}"
    [ "$STATE" = "available" ] && break
    sleep 5
done
[ "$STATE" = "available" ] || die "upload ${UPLOAD_ID} never became available (last state: ${STATE})"

# Which version this one replaces. Nexus retires the previous *main* version by itself -
# main is exclusive, so it can work out what is being replaced - but an optional file keeps
# every current version listed, which is how 0.6.22 stayed on the page next to 0.6.23 and had
# to be set to Old by hand. There is no endpoint for changing a version's category
# (/mod-file-versions/{id} is read-only), so saying up front what this replaces is the only
# handle the API offers.
if [ "$SUPERSEDE" = "1" ] && [ -z "$PREVIOUS_VERSION_ID" ]; then
    EXISTING_JSON="$(nexus_api GET "/mod-files/${FILE_ID}/versions" || true)"
    PREVIOUS_VERSION_ID="$(printf '%s' "$EXISTING_JSON" \
        | jq -r '[.data.versions[]? | select((.category // "") | test("old_version|archived") | not)]
                 | first | .id // empty' 2>/dev/null || true)"
    if [ -n "$PREVIOUS_VERSION_ID" ]; then
        PREVIOUS_VERSION="$(printf '%s' "$EXISTING_JSON" | jq -r --arg id "$PREVIOUS_VERSION_ID" \
            '[.data.versions[]? | select(.id == $id) | .version] | first // "?"')"
        log "this version replaces ${PREVIOUS_VERSION} (${PREVIOUS_VERSION_ID})"
    else
        log "no current version on this file to replace"
    fi
fi

log "step 6/7: creating the file version"
VERSION_BODY="$(jq -n \
    --arg upload_id "$UPLOAD_ID" --arg name "$DISPLAY_NAME" --arg version "$VERSION" \
    --arg category "$CATEGORY" --argjson archive "$ARCHIVE_EXISTING" \
    --argjson update_mod_version "$UPDATE_MOD_VERSION" \
    --arg previous_version_id "$PREVIOUS_VERSION_ID" \
    '{upload_id: $upload_id, name: $name, version: $version, file_category: $category,
      archive_existing_file: $archive, update_mod_version: $update_mod_version}
     + (if $previous_version_id == "" then {} else {previous_version_id: $previous_version_id} end)')"
VERSION_JSON="$(check_response "$(nexus_api POST "/mod-files/${FILE_ID}/versions" "$VERSION_BODY")" "creating the file version")"
VERSION_ID="$(printf '%s' "$VERSION_JSON" | jq -r '.data.version.id // "?"')"
log "file version created: ${VERSION_ID}"

if [ -n "$CHANGELOG_TEXT" ]; then
    log "step 7/7: posting the changelog"
    CHANGELOG_BODY="$(jq -n --arg version "$VERSION" --arg changelog "$CHANGELOG_TEXT" \
        '{version: $version, changelog: $changelog}')"
    check_response "$(nexus_api POST "/mods/${MOD_ID}/changelogs" "$CHANGELOG_BODY")" "posting the changelog" >/dev/null
    log "changelog posted"
else
    log "step 7/7: no changelog given, skipping"
fi

echo "NEXUS_PUBLISH_RESULT $(jq -n --arg package "$PACKAGE_NAME" --arg version "$VERSION" \
    --arg file_id "$FILE_ID" --arg version_id "$VERSION_ID" \
    --argjson changelog_posted "$( [ -n "$CHANGELOG_TEXT" ] && echo true || echo false )" \
    '{package: $package, version: $version, file_id: $file_id, version_id: $version_id,
      changelog_posted: $changelog_posted}')"
