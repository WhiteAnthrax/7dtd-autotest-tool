#!/usr/bin/env bash
# Builds the release ZIP that gets published, from a named commit, and records which commit
# that was.
#
# This exists because the step used to be manual. On 2026-08-03 both lines were built by hand
# minutes after their PRs were merged; `main` had been pulled and `v26-work` had not, so the
# v2.6 package was built from the commit *before* its release commit. Nothing caught it: the
# ZIP carries a version number, not a provenance, and the verification only knew the file.
# `git archive` reads the local branch, so "which commit is this" is decided by whatever the
# working copy happens to be pointing at - which is exactly the thing a human forgets and a
# script does not.
#
# What it does:
#   1. resolves <ref> to a commit, and refuses when the local branch is behind its remote
#   2. archives that commit and builds it Release on the Windows host, where the csproj's
#      PackageMod target writes dist\VisitedTraderTeleport-<version>.zip
#   3. copies the ZIP back and writes <zip>.provenance.json beside it - commit, ref, version,
#      sha256 - which bin/run-release-verification.sh then carries into its own result
#
# Usage: build-release-package.sh --profile <v3|v26> [--ref <branch|tag|commit>]
#                                 [--out <dir>] [--allow-behind]
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/ssh-omen.sh
source "$ROOT_DIR/lib/ssh-omen.sh"

trace_errors

usage() {
    cat <<EOF
Usage: $0 --profile <v3|v26> [--ref <branch|tag|commit>] [--out <dir>] [--allow-behind]

Builds the publishable ZIP from a specific commit and records which one.

  --profile <name>   Which config/<name>.env to build for. Decides the game flavour, the
                     reference DLLs and the repository the sources come from.
  --ref <ref>        What to build. Defaults to the profile's VTT_BRANCH.
  --out <dir>        Where to put the ZIP. Defaults to output/<profile>/dist/.
  --allow-behind     Build anyway when the local ref is behind its remote. Only reasonable
                     when rebuilding an older release on purpose.

Writes <out>/<zip> and <out>/<zip>.provenance.json. Feed the ZIP to
bin/run-release-verification.sh, which records the provenance in its own result, and then to
bin/publish-to-nexus.sh, which refuses anything it cannot match to a passing verification.
EOF
}

PROFILE=""
REF=""
OUT_DIR=""
ALLOW_BEHIND=0
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --ref) REF="${2:-}"; shift 2 ;;
        --out) OUT_DIR="${2:-}"; shift 2 ;;
        --allow-behind) ALLOW_BEHIND=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
done
[ -n "$PROFILE" ] || { usage; die "--profile is required"; }

load_profile "$PROFILE"
require_cmd git tar ssh scp jq sha256sum
for var in VTT_REPO_PATH VTT_BRANCH GAME_FLAVOR CLIENT_GAME_PATH OMEN_SCRATCH_DIR; do
    require_var "$var"
done
[ -d "$VTT_REPO_PATH" ] || die "VTT_REPO_PATH does not exist: $VTT_REPO_PATH"

REF="${REF:-$VTT_BRANCH}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/$PROFILE/dist}"
mkdir -p "$OUT_DIR"

COMMIT="$(git -C "$VTT_REPO_PATH" rev-parse --verify "${REF}^{commit}" 2>/dev/null)" \
    || die "'$REF' is not a commit in $VTT_REPO_PATH"

# The check that would have caught the mistake this script exists to prevent. A local branch
# that is behind its remote still archives happily; the ZIP just quietly predates the release.
git -C "$VTT_REPO_PATH" fetch -q origin || log "warn: could not fetch origin, the behind-check may be stale"
UPSTREAM="$(git -C "$VTT_REPO_PATH" rev-parse --verify --quiet "origin/${REF}" || true)"
if [ -n "$UPSTREAM" ] && [ "$UPSTREAM" != "$COMMIT" ]; then
    if git -C "$VTT_REPO_PATH" merge-base --is-ancestor "$COMMIT" "$UPSTREAM"; then
        BEHIND="$(git -C "$VTT_REPO_PATH" rev-list --count "${COMMIT}..${UPSTREAM}")"
        MSG="local '$REF' is $BEHIND commit(s) behind origin/$REF - building it would package an older state than the branch's tip"
        if [ "$ALLOW_BEHIND" = "1" ]; then
            log "warn: $MSG (continuing because --allow-behind was given)"
        else
            die "$MSG. Run: git -C $VTT_REPO_PATH pull  (or pass --allow-behind on purpose)"
        fi
    else
        log "warn: local '$REF' and origin/$REF have diverged; building the local one ($(printf '%.12s' "$COMMIT"))"
    fi
fi

SUBJECT="$(git -C "$VTT_REPO_PATH" log -1 --format='%s' "$COMMIT")"
log "building $REF @ $(printf '%.12s' "$COMMIT") ($SUBJECT)"

WORK_REMOTE="${OMEN_SCRATCH_DIR}\\vtt-release-build"
TMP_TAR="$(mktemp --suffix=.tar.gz)"
trap 'rm -f "$TMP_TAR"' EXIT

log "archiving the commit..."
git -C "$VTT_REPO_PATH" archive "$COMMIT" | gzip > "$TMP_TAR"

log "transferring to $OMEN_SSH_HOST:$WORK_REMOTE..."
# A leftover dist/ from an earlier build would let a failed build hand back a stale ZIP.
run_on_omen_cmd "if (Test-Path '${WORK_REMOTE}') { Remove-Item '${WORK_REMOTE}' -Recurse -Force }; New-Item -ItemType Directory -Force -Path '${WORK_REMOTE}' | Out-Null"
copy_to_omen "$TMP_TAR" "${WORK_REMOTE}\\vtt.tar.gz"
run_on_omen_cmd "tar -xzf '${WORK_REMOTE}\\vtt.tar.gz' -C '${WORK_REMOTE}'"

log "building Release..."
run_on_omen_script "$ROOT_DIR/lib/windows/Build-Mod.ps1" \
    -ProjectPath "\"${WORK_REMOTE}\\src\\VisitedTraderTeleport\\VisitedTraderTeleport.csproj\"" \
    -GamePath "\"${CLIENT_GAME_PATH}\"" \
    -RepositoryPath "\"${WORK_REMOTE}\"" \
    -Configuration Release

# The version comes from the packaged ModInfo.xml rather than from anything this script
# guesses, because that is what named the ZIP.
VERSION="$(run_on_omen_cmd "([xml](Get-Content -LiteralPath '${WORK_REMOTE}\\mod\\VisitedTraderTeleport\\ModInfo.xml' -Raw)).xml.Version.value" | tr -d '\r' | tail -1)"
[ -n "$VERSION" ] || die "could not read the mod version from the built ModInfo.xml"

ZIP_NAME="VisitedTraderTeleport-${VERSION}.zip"
log "retrieving ${ZIP_NAME}..."
copy_from_omen "${WORK_REMOTE}\\dist\\${ZIP_NAME}" "$OUT_DIR/$ZIP_NAME"

ZIP_SHA="$(sha256sum "$OUT_DIR/$ZIP_NAME" | cut -d' ' -f1)"
jq -n --arg package "$ZIP_NAME" --arg sha256 "$ZIP_SHA" --arg commit "$COMMIT" \
    --arg ref "$REF" --arg version "$VERSION" --arg profile "$PROFILE" \
    --arg subject "$SUBJECT" \
    '{package: $package, sha256: $sha256, source_commit: $commit, ref: $ref,
      version: $version, profile: $profile, commit_subject: $subject}' \
    > "$OUT_DIR/${ZIP_NAME}.provenance.json"

log "built $OUT_DIR/$ZIP_NAME"
log "  version ${VERSION}, commit $(printf '%.12s' "$COMMIT"), sha256 $(printf '%.12s' "$ZIP_SHA")"
echo "RELEASE_PACKAGE $(jq -c . "$OUT_DIR/${ZIP_NAME}.provenance.json")"
