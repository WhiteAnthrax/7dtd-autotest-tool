#!/usr/bin/env bash
# Releases one line end to end: build, verify, GitHub release, Nexus, and a check that the
# page came out clean.
#
# It exists because the August 2026 release took a dozen hand-typed steps - two ids and a
# category looked up in the runbook, a changelog file extracted from the other branch by hand,
# release notes pasted together, and afterwards a file left in the wrong section of the Nexus
# page that had to be archived in a browser. Every one of those is a place to get it wrong,
# and one of them was got wrong.
#
#   ./bin/release.sh --line v3          # 3.x line, from main
#   ./bin/release.sh --line v26         # v2.6 line, from v26-work
#   ./bin/release.sh --line v3 --dry-run
#
# What it does, in order:
#   1. reads the line's settings from config/release-lines.conf
#   2. checks the ref is current, gh is authenticated, the key is readable, the changelog
#      files exist - before anything is built
#   3. builds the package from that exact commit (bin/build-release-package.sh)
#   4. runs the release gate against it (bin/run-release-verification.sh) unless it has
#      already passed for these exact bytes
#   5. creates the GitHub release, notes assembled from the repo's own CHANGELOG
#   6. uploads to Nexus (bin/publish-to-nexus.sh) as a new version of the existing file
#   7. reads the page back and reports every file's state, failing if anything is left
#      looking like two current versions
#
# Nothing here holds a credential: gh uses its own login, the Nexus key comes from
# ~/.config/nexus-upload.env.
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

LINES_CONF="${RELEASE_LINES_CONF:-$ROOT_DIR/config/release-lines.conf}"
NEXUS_ENV_FILE="${NEXUS_ENV_FILE:-$HOME/.config/nexus-upload.env}"

usage() {
    cat <<EOF
Usage: $0 --line <v3|v26> [--version <x.y.z>] [--languages a,b,c]
          [--skip-verify] [--dry-run] [--yes]

  --line <name>      Which release line. Its branch, Nexus file id, category and wording all
                     come from $(basename "$LINES_CONF").
  --version <x.y.z>  Override the version. By default it is read from the mod's ModInfo.xml
                     at the commit being released, which is what names the ZIP anyway.
  --languages a,b,c  Passed to the release gate (default: whatever it defaults to).
  --skip-verify      Only if the gate has already passed for this exact ZIP; it is still
                     checked, and refused when the hash does not match.
  --dry-run          Do everything up to and including the build and the gate, then print
                     what would be published and stop.
  --yes              Do not ask before publishing.

The GitHub release notes are the matching section of the mod's CHANGELOG.md, with the line's
header and the standard verification note around it. The Nexus changelog is
docs/NexusModsChangelog-<version>.txt from the same commit.
EOF
}

LINE=""
VERSION=""
LANGUAGES=""
SKIP_VERIFY=0
DRY_RUN=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --line) LINE="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --languages) LANGUAGES="${2:-}"; shift 2 ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
done
[ -n "$LINE" ] || { usage; die "--line is required"; }
[ -f "$LINES_CONF" ] || die "no release line config at $LINES_CONF"

require_cmd git jq gh curl sha256sum

# shellcheck disable=SC1090 # path is configurable; the file holds no secrets
source "$LINES_CONF"

line_setting() {
    local name="${LINE}_$1"
    printf '%s' "${!name-}"
}

PROFILE="$(line_setting PROFILE)"
REF="$(line_setting REF)"
FILE_ID="$(line_setting NEXUS_FILE_ID)"
CATEGORY="$(line_setting NEXUS_CATEGORY)"
GAME_LABEL="$(line_setting GAME_LABEL)"
UPDATE_MOD_VERSION="$(line_setting UPDATE_MOD_VERSION)"
RELEASE_HEADER="$(line_setting RELEASE_HEADER)"
for value in PROFILE REF FILE_ID CATEGORY GAME_LABEL; do
    [ -n "$(eval "printf '%s' \"\$$value\"")" ] || die "line '$LINE' has no ${value} in $LINES_CONF"
done

load_profile "$PROFILE"
require_var VTT_REPO_PATH
[ -d "$VTT_REPO_PATH" ] || die "VTT_REPO_PATH does not exist: $VTT_REPO_PATH"

# --- preflight, before anything is built -----------------------------------------------
# All of it up front: finding out that the changelog is missing after a twenty-minute
# verification run is how an evening goes.
log "preflight for the ${LINE} line (${REF})"

git -C "$VTT_REPO_PATH" fetch -q origin || log "warn: could not fetch origin; the up-to-date check may be stale"
LOCAL_COMMIT="$(git -C "$VTT_REPO_PATH" rev-parse --verify "${REF}^{commit}" 2>/dev/null)" \
    || die "'$REF' is not a commit in $VTT_REPO_PATH"
REMOTE_COMMIT="$(git -C "$VTT_REPO_PATH" rev-parse --verify --quiet "origin/${REF}" || true)"
if [ -n "$REMOTE_COMMIT" ] && [ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]; then
    die "local ${REF} is not what origin has - pull (or push) first. local $(printf '%.12s' "$LOCAL_COMMIT"), origin $(printf '%.12s' "$REMOTE_COMMIT")"
fi

if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$VTT_REPO_PATH" show "${REF}:mod/VisitedTraderTeleport/ModInfo.xml" \
        | grep -oP '<Version\s+value="\K[^"]+' | head -1 || true)"
    [ -n "$VERSION" ] || die "could not read the version from ModInfo.xml at ${REF}"
fi
TAG="v${VERSION}"
log "releasing ${VERSION} from ${REF} @ $(printf '%.12s' "$LOCAL_COMMIT")"

# The changelog entry has to exist before the ZIP is built, in both forms.
CHANGELOG_SECTION="$(git -C "$VTT_REPO_PATH" show "${REF}:CHANGELOG.md" \
    | awk -v v="## ${VERSION} " 'index($0, v) == 1 {found=1; next} found && /^## / {exit} found {print}' \
    | sed '/^[[:space:]]*$/d')"
[ -n "$CHANGELOG_SECTION" ] || die "CHANGELOG.md at ${REF} has no section for ${VERSION}"

NEXUS_CHANGELOG_PATH="docs/NexusModsChangelog-${VERSION}.txt"
NEXUS_CHANGELOG_FILE="$(mktemp --suffix=.txt)"
trap 'rm -f "$NEXUS_CHANGELOG_FILE"' EXIT
git -C "$VTT_REPO_PATH" show "${REF}:${NEXUS_CHANGELOG_PATH}" > "$NEXUS_CHANGELOG_FILE" 2>/dev/null \
    || die "${NEXUS_CHANGELOG_PATH} does not exist at ${REF} - the Nexus changelog is written per release"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
if [ -z "${NEXUS_API_KEY:-}" ] && [ -f "$NEXUS_ENV_FILE" ]; then
    # shellcheck disable=SC1090 # path is configurable and lives outside the repo on purpose
    source "$NEXUS_ENV_FILE"
fi
[ -n "${NEXUS_API_KEY:-}" ] || die "NEXUS_API_KEY is not set and $NEXUS_ENV_FILE has no key"

if git -C "$VTT_REPO_PATH" rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
    log "warn: tag ${TAG} already exists locally"
fi
if gh release view "$TAG" --repo "$(git -C "$VTT_REPO_PATH" remote get-url origin)" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
        log "note: a GitHub release for ${TAG} already exists - a real run would stop here"
    else
        die "a GitHub release for ${TAG} already exists - bump the version, or delete that release first"
    fi
fi

# --- build -------------------------------------------------------------------------------
PACKAGE="$ROOT_DIR/output/$PROFILE/dist/VisitedTraderTeleport-${VERSION}.zip"
# A rehearsal must not replace the package a real run built and verified. Two builds of the
# same commit are not byte-identical (the compiler stamps each one), so rebuilding here would
# leave a ZIP on disk that no longer matches the verification - and looks exactly like the one
# that does.
if [ "$DRY_RUN" = "1" ] && [ -f "$PACKAGE" ]; then
    log "dry run: keeping the package already in output/$PROFILE/dist"
else
    log "building the package"
    "$BIN_DIR/build-release-package.sh" --profile "$PROFILE" --ref "$REF" \
        || die "building the release package failed"
fi
[ -f "$PACKAGE" ] || die "the build did not produce ${PACKAGE}"
PACKAGE_SHA="$(sha256sum "$PACKAGE" | cut -d' ' -f1)"

# --- verify ------------------------------------------------------------------------------
VERIFY_FILE="$ROOT_DIR/output/$PROFILE/release-verification-result.json"
verification_matches() {
    [ -f "$VERIFY_FILE" ] || return 1
    [ "$(jq -r '.sha256 // ""' "$VERIFY_FILE")" = "$PACKAGE_SHA" ] || return 1
    [ "$(jq -r '.ok // false' "$VERIFY_FILE")" = "true" ]
}

if [ "$DRY_RUN" = "1" ]; then
    # A rehearsal should take a minute, not half an hour. The gate is what a real run spends
    # its time on and what it refuses to publish without; there is nothing to learn from
    # running it against a package nobody is about to release.
    if verification_matches; then
        log "dry run: the gate has already passed for these bytes"
    else
        log "dry run: skipping the gate (a real run would spend 20-30 minutes here)"
    fi
elif [ "$SKIP_VERIFY" = "1" ]; then
    verification_matches \
        || die "--skip-verify was given but no passing verification exists for these exact bytes (sha256 ${PACKAGE_SHA:0:12})"
    log "skipping the gate: it already passed for sha256 ${PACKAGE_SHA:0:12}"
else
    log "running the release gate (this takes 20-30 minutes)"
    VERIFY_ARGS=(--profile "$PROFILE" --package "$PACKAGE" --fresh-save)
    [ -n "$LANGUAGES" ] && VERIFY_ARGS+=(--languages "$LANGUAGES")
    "$BIN_DIR/run-release-verification.sh" "${VERIFY_ARGS[@]}" \
        || die "the release gate did not pass - nothing was published"
    verification_matches || die "the gate passed but its result does not match this ZIP"
fi

# --- what is about to happen --------------------------------------------------------------
# "Players on the other game version should use X instead" names the other line's current
# version, read from the other branch rather than typed - that sentence was wrong in an
# earlier release because it still pointed at a version that had since been superseded.
case "$LINE" in
    v3)  OTHER_REF="${v26_REF:-v26-work}" ;;
    v26) OTHER_REF="${v3_REF:-main}" ;;
    *)   OTHER_REF="" ;;
esac
OTHER_VERSION=""
if [ -n "$OTHER_REF" ]; then
    OTHER_VERSION="$(git -C "$VTT_REPO_PATH" show "${OTHER_REF}:mod/VisitedTraderTeleport/ModInfo.xml" 2>/dev/null \
        | grep -oP '<Version\s+value="\K[^"]+' | head -1 || true)"
fi
HEADER="${RELEASE_HEADER//%OTHER_VERSION%/${OTHER_VERSION:-the other}}"
DISPLAY_NAME="Travel Between Visited Traders ${VERSION} (for ${GAME_LABEL})"
RELEASE_NOTES="$(printf '%s\n\n%s\n\n%s\n' "$HEADER" "$CHANGELOG_SECTION" "${RELEASE_FOOTER:-}")"

cat <<EOF

About to publish the ${LINE} line:
  version          ${VERSION}  (tag ${TAG})
  commit           $(printf '%.12s' "$LOCAL_COMMIT")  on ${REF}
  package          ${PACKAGE}
  sha256           ${PACKAGE_SHA}
  GitHub release   ${TAG} "VisitedTraderTeleport ${VERSION}" with the ZIP attached
  Nexus file       ${FILE_ID} as "${DISPLAY_NAME}" (${CATEGORY})
  page version     $([ "$UPDATE_MOD_VERSION" = "true" ] && echo "set to ${VERSION}" || echo "left alone")

--- GitHub release notes ---
${RELEASE_NOTES}
--- Nexus changelog ---
$(cat "$NEXUS_CHANGELOG_FILE")
----------------------------
EOF

if [ "$DRY_RUN" = "1" ]; then
    log "dry run: nothing was published"
    exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
    printf 'Publish this? [y/N] '
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) die "cancelled" ;;
    esac
fi

# --- GitHub --------------------------------------------------------------------------------
log "creating the GitHub release ${TAG}"
(
    cd "$VTT_REPO_PATH" || exit 1
    gh release create "$TAG" --target "$LOCAL_COMMIT" \
        --title "VisitedTraderTeleport ${VERSION}" --notes "$RELEASE_NOTES" "$PACKAGE"
) || die "creating the GitHub release failed"

# --- Nexus ---------------------------------------------------------------------------------
log "publishing to Nexus Mods"
PUBLISH_ARGS=(--profile "$PROFILE" --package "$PACKAGE" --version "$VERSION"
              --file-id "$FILE_ID" --mod-id "$NEXUS_MOD_ID" --category "$CATEGORY"
              --display-name "$DISPLAY_NAME" --changelog "$NEXUS_CHANGELOG_FILE" --yes)
[ "$UPDATE_MOD_VERSION" = "true" ] && PUBLISH_ARGS+=(--update-mod-version)
"$BIN_DIR/publish-to-nexus.sh" "${PUBLISH_ARGS[@]}" || die "publishing to Nexus failed"

# --- did the page come out clean? ------------------------------------------------------------
log "checking how the page looks now"
"$BIN_DIR/check-nexus-page.sh" --mod-id "$NEXUS_MOD_ID" || {
    log "warn: the page needs a look - see above"
    exit 1
}

log "released ${VERSION} on the ${LINE} line"
