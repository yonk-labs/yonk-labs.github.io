#!/usr/bin/env bash
# Release-gate for future-dated blog posts.
#
# Each unreleased post in content/blog/*/index.md carries:
#
#   build:
#     list: never
#
# That keeps the post's URL live (buildFuture = true in hugo.toml) but hides it
# from the blog list, homepage recent, RSS, sitemap, and tag pages.
#
# This script strips that build block from any post whose `date:` is today or
# earlier, in $TZ (deploy.yml sets TZ=America/New_York). Run BEFORE `hugo`.
#
# Idempotent: git is the source of truth; the CI rerun next day picks up the
# next batch. The stripped files live only in the CI workspace — no commits.

set -euo pipefail

cd "$(dirname "$0")/.."

today=$(date +%Y-%m-%d)
released=0

for md in content/blog/*/index.md; do
  # Only care about posts that are gated.
  grep -q '^  list: never$' "$md" || continue

  # Extract `date:` from the first front-matter block.
  post_date=$(awk '
    /^---$/ { fm++; next }
    fm == 1 && /^date:/ { sub(/^date:[[:space:]]*/, ""); sub(/[[:space:]]+.*/, ""); print; exit }
  ' "$md")

  if [[ -z "$post_date" ]]; then
    echo "skip (no date): $md" >&2
    continue
  fi

  if [[ "$post_date" > "$today" ]]; then
    echo "hold until $post_date: $md"
    continue
  fi

  # Remove the two-line `build:\n  list: never` block.
  tmp=$(mktemp)
  awk '
    /^build:$/ { buf = $0; getline next_line
                 if (next_line == "  list: never") { next }
                 print buf; print next_line; next }
    { print }
  ' "$md" > "$tmp"
  mv "$tmp" "$md"
  echo "released (date=$post_date): $md"
  released=$((released + 1))
done

echo "release-scheduled-posts: $released post(s) released today ($today)"
