#!/bin/bash
# Makes an Inkwell release.
#
#   scripts/release.sh 0.2.0            prepare: version, changelog, commit, tag, build the DMG (nothing leaves this Mac)
#   scripts/release.sh 0.2.0 --publish  same, then push main and the tag and create the GitHub release with the DMG
#   scripts/release.sh 0.2.0 --publish-only   publish a release prepared earlier
#
# Before running it, list the changes under "## [Unreleased]" in CHANGELOG.md. The script moves them under the new
# version with today's date, so the release notes are exactly that section.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
MODE="${2:-}"
TAG="v$VERSION"
DMG="dist/Inkwell-$VERSION.dmg"
REPO="${INKWELL_REPO:-jaiedsabid/Inkwell}"

die() { echo "release: $*" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "usage: scripts/release.sh <major.minor.patch> [--publish | --publish-only]"
[[ -z "$MODE" || "$MODE" == "--publish" || "$MODE" == "--publish-only" ]] || die "unknown option $MODE"

# The notes for one version: everything under its heading, up to the next "## [" heading.
notes() { awk -v v="$1" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    on { print }' CHANGELOG.md | sed -e '/./,$!d'; }

publish() {
    command -v gh >/dev/null || die "the GitHub CLI (gh) is needed to publish"
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG doesn't exist; prepare the release first"
    [ -f "$DMG" ] || die "$DMG is missing; prepare the release first"
    grep -q "Inkwell-$VERSION.dmg" dist/appcast.xml 2>/dev/null || die "dist/appcast.xml isn't for $VERSION; prepare the release first"
    git push origin main
    git push origin "$TAG"
    local body; body="$(mktemp)"
    {
        notes "$VERSION"
        echo
        echo "### Install"
        echo
        echo "Download \`Inkwell-$VERSION.dmg\` below, open it and drag Inkwell to Applications. Needs macOS 15 or later on Apple silicon."
        echo "Releases aren't notarized yet, so macOS asks you to confirm once: see [Install](https://github.com/$REPO#install)."
        echo
        echo "SHA-256: \`$(cut -d' ' -f1 "$DMG.sha256")\`"
    } > "$body"
    # appcast.xml rides along: the app reads it from the latest release.
    # Inkwell.dmg, a copy under a fixed name, so …/releases/latest/download/Inkwell.dmg is always the newest (the website uses it).
    cp "$DMG" dist/Inkwell.dmg
    gh release create "$TAG" "$DMG" "$DMG.sha256" dist/appcast.xml dist/Inkwell.dmg --repo "$REPO" --title "Inkwell $VERSION" --notes-file "$body" --verify-tag
    rm -f "$body"
    echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"
}

if [ "$MODE" == "--publish-only" ]; then publish; exit 0; fi

[ "$(git branch --show-current)" == "main" ] || die "releases are made from main"
[ -z "$(git status --porcelain)" ] || die "commit or stash your changes first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"

# Changelog: Unreleased → this version, with a fresh empty Unreleased section on top.
grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md has no ## [Unreleased] section"
[ -n "$(notes Unreleased | tr -d '[:space:]')" ] || die "nothing listed under ## [Unreleased] in CHANGELOG.md"
TODAY="$(date +%Y-%m-%d)"
awk -v v="$VERSION" -v d="$TODAY" '
    !done && /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; done = 1; next }
    { print }' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
# Comparison links at the bottom, rebuilt from the version headings (newest first).
grep -v '^\[[^]]*\]: ' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > CHANGELOG.md.tmp
VERSIONS=($(grep -o '^## \[[0-9][^]]*\]' CHANGELOG.md.tmp | sed 's/^## \[\(.*\)\]/\1/'))
{
    echo
    echo "[Unreleased]: https://github.com/$REPO/compare/v${VERSIONS[0]}...HEAD"
    for i in "${!VERSIONS[@]}"; do
        v="${VERSIONS[$i]}"; older="${VERSIONS[$((i + 1))]:-}"
        if [ -n "$older" ]; then echo "[$v]: https://github.com/$REPO/compare/v$older...v$v"
        else echo "[$v]: https://github.com/$REPO/releases/tag/v$v"; fi
    done
} >> CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md

echo "$VERSION" > VERSION
git add VERSION CHANGELOG.md
git commit -m "Release $VERSION"
git tag -a "$TAG" -m "Inkwell $VERSION"

# Build number: the commit count, so it always goes up (Sparkle compares it to decide what's newer).
BUILD="$(git rev-list --count HEAD)"
INKWELL_VERSION="$VERSION" INKWELL_BUILD="$BUILD" ./build.sh
mv dist/Inkwell.dmg "$DMG"
(cd dist && shasum -a 256 "Inkwell-$VERSION.dmg" > "Inkwell-$VERSION.dmg.sha256")
codesign --verify --deep --strict dist/Inkwell.app && echo "Signature OK"

# Sparkle feed: sign the DMG with the update key in the login Keychain (account "inkwell") and describe it.
SIGN_UPDATE="$(find .build/artifacts -type f -name sign_update -path '*Sparkle/bin/*' | head -1)"
[ -x "$SIGN_UPDATE" ] || die "Sparkle's sign_update not found; run swift package resolve"
SIG_LINE="$("$SIGN_UPDATE" --account inkwell "$DMG")" || die "couldn't sign the update; is the Sparkle key (account inkwell) in the Keychain?"
ED_SIG="$(echo "$SIG_LINE" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIG_LINE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || die "unexpected sign_update output: $SIG_LINE"
NOTES_FILE="$(mktemp)"; notes "$VERSION" > "$NOTES_FILE"
scripts/appcast.py "$VERSION" "$BUILD" "$DMG" "$ED_SIG" "$LENGTH" "$NOTES_FILE" dist/appcast.xml "$REPO"
rm -f "$NOTES_FILE"
echo "Update feed: dist/appcast.xml (build $BUILD)"
echo "Prepared $TAG: $DMG"
echo "Notes:"; notes "$VERSION"

if [ "$MODE" == "--publish" ]; then publish
else echo "Publish with: scripts/release.sh $VERSION --publish-only"; fi
