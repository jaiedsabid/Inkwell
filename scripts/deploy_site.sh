#!/bin/bash
# Publishes site/ (the website) to the gh-pages branch, which GitHub Pages serves at https://jaiedsabid.github.io/Inkwell/.
#
#   scripts/deploy_site.sh           commit site/ to gh-pages and push it
#   scripts/deploy_site.sh --local   only update the local gh-pages branch
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f site/index.html ] || { echo "site/index.html is missing" >&2; exit 1; }
SRC="$(git rev-parse --short HEAD)"
TMP="$(mktemp -d)"
trap 'git worktree remove --force "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

if git show-ref -q refs/heads/gh-pages; then
    git worktree add -q "$TMP" gh-pages
elif git ls-remote -q --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git fetch -q origin gh-pages:gh-pages && git worktree add -q "$TMP" gh-pages
else
    git worktree add -q --detach "$TMP" && (cd "$TMP" && git checkout -q --orphan gh-pages && git rm -rfq .)
fi

# Replace everything with the current site.
find "$TMP" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R site/. "$TMP/"
touch "$TMP/.nojekyll"
cd "$TMP"
git add -A
if git diff --cached --quiet; then echo "Site unchanged."; else git commit -qm "Deploy site from $SRC"; echo "Committed site from $SRC to gh-pages."; fi
if [ "${1:-}" != "--local" ]; then git push -q origin gh-pages && echo "Pushed gh-pages."; fi
