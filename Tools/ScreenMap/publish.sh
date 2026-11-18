#!/bin/sh
# Publishes <site dir> (index.html and shots/) to GitHub Pages: the gh-pages branch, served at
# https://danfoygel.github.io/screenthyme/. The repo is public: check the screenshots hold only test data.
#
#   Tools/ScreenMap/publish.sh <site dir>
set -e
SITE=$(cd "${1:?usage: publish.sh <site dir>}" && pwd)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PAGES=$(mktemp -d)/gh-pages
git -C "$ROOT" fetch -q origin gh-pages
git -C "$ROOT" worktree add -q --detach "$PAGES" origin/gh-pages
rsync -a --delete --exclude .git --exclude .nojekyll "$SITE"/ "$PAGES"/
cd "$PAGES"
git add -A
if git diff --cached --quiet; then
  echo "gh-pages is already up to date"
else
  git commit -q -m "Update the screen map ($(git -C "$ROOT" rev-parse --short HEAD))"
  git push -q origin HEAD:gh-pages
  echo "published: https://danfoygel.github.io/screenthyme/ (live in a minute or two)"
fi
git -C "$ROOT" worktree remove "$PAGES"
