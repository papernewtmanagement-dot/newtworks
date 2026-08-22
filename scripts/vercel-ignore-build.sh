#!/usr/bin/env bash
#
# Decides whether Vercel should skip a build for the current commit.
#
#   exit 0 = SKIP the build
#   exit 1 = RUN the build
#
# The default is ALWAYS to run. We skip only when every single changed
# file sits in a path that cannot affect what Vercel builds or serves.
# Any doubt, any error, anything unrecognised -> we build.
#
# Referenced from vercel.json as:
#   "ignoreCommand": "bash scripts/vercel-ignore-build.sh"

set -u

# Paths that cannot affect the Vercel build or the site it serves.
# Anything NOT listed here causes a build, so new directories are safe
# by default.
#
#   supabase/migrations/  database migrations, applied to Supabase
#   supabase/functions/   edge function sources, deployed to Supabase
#   edge-bundles/         edge function bundles, deployed to Supabase.
#                         Deliberately NOT dist/: dist/ is Vite's output
#                         folder and Vite empties it at the start of every
#                         build, which used to delete every committed
#                         bundle. Separated 2026-08-22.
#   docs/                 documentation
#   _scratch/             scratch space
#   .github/              GitHub Actions workflows, run by GitHub
#   *.md at the repo root README, CLAUDE, handoff notes, runbooks
#
# Deliberately NOT skippable: src/, api/, public/, tools/, NewtworksApp.jsx,
# index.html, package.json, vite.config.js, vercel.json.
# tools/ matters because package.json runs "prebuild": node tools/schema-audit.js
# on every build.
SKIPPABLE='^(supabase/migrations/|supabase/functions/|edge-bundles/|docs/|_scratch/|\.github/|[^/]+\.md$)'

PREV="${VERCEL_GIT_PREVIOUS_SHA:-}"

# No record of a previous successful deploy -> build.
if [ -z "$PREV" ]; then
  echo "No previous successful deploy recorded. Building."
  exit 1
fi

# Vercel checks out a shallow copy, so the previous commit may not be
# present locally. Try to fetch it before giving up.
if ! git cat-file -e "${PREV}^{commit}" 2>/dev/null; then
  git fetch --no-tags --depth=200 origin "$PREV" 2>/dev/null || true
fi
if ! git cat-file -e "${PREV}^{commit}" 2>/dev/null; then
  echo "Previous deploy commit $PREV not reachable in this checkout. Building to be safe."
  exit 1
fi

CHANGED="$(git diff --name-only "$PREV" HEAD 2>/dev/null)" || {
  echo "Could not compare against $PREV. Building to be safe."
  exit 1
}

if [ -z "$CHANGED" ]; then
  echo "No file changes since the last successful deploy. Skipping."
  exit 0
fi

if echo "$CHANGED" | grep -qvE "$SKIPPABLE"; then
  echo "Changes that affect the build. Building. Files:"
  echo "$CHANGED" | grep -vE "$SKIPPABLE"
  exit 1
fi

echo "Only non-build files changed. Skipping build. Files:"
echo "$CHANGED"
exit 0
