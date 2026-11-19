#!/usr/bin/env bash
# Release bookkeeping for prod deploys; run by the release action (release/action.yml).
#
#   release-after-deploy.sh --pre <deploy-sha> <before-sha>
#       At the START of a prod deploy: tag pre-v<X.Y.Z> at <before-sha>, the prod commit that was
#       live before this merge (rollback point). X.Y.Z is the version <deploy-sha> will get.
#
#   release-after-deploy.sh <deploy-sha>
#       After the deploy PASSED its health check: tag v<X.Y.Z> at <deploy-sha>, move the `release`
#       branch there (it always points at what is live), then delete the feat/ fix/ hotfix/
#       branches fully contained in it. Lists the merged branches and PRs in the run summary and,
#       with GH_TOKEN set, in a GitHub Release for the tag and a comment on the prod PR.
#
# Version (semantic): the latest v* tag + 1. Any feat/ merged since the last release → MINOR;
# otherwise PATCH. MAJOR bumps are made by hand (push tag v<X+1>.0.0 yourself). Both modes compute
# the version the same way, so pre-vX.Y.Z and vX.Y.Z always match.
#
# Older releases were branches (release/vX.Y.Z, release/pre-vX.Y.Z): each run turns any it finds
# into the matching tag and deletes the branch.
#
#   DRY_RUN=1   print what would happen; change nothing
#   REMOTE      git remote to use (default: origin)
#
# Tags are lightweight on purpose: GitHub refuses a new annotated tag object from the workflow token
# when the tagged commit's workflow files differ from the default branch's ("refusing to allow a
# GitHub App to create or update workflow ... without `workflows` permission"), which is exactly
# the pre-v tag of a release that changes a workflow.
#
# Assumes all remote branches are fetched into refs/remotes/$REMOTE/* and all tags are fetched.
set -euo pipefail

REMOTE="${REMOTE:-origin}"
DRY_RUN="${DRY_RUN:-}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'

run() { if [ -n "$DRY_RUN" ]; then echo "[dry-run] $*"; else "$@"; fi; }
say() { echo "$*"; echo "$*" >> "$SUMMARY"; }
usage() { echo "usage: $0 <deploy-sha> | $0 --pre <deploy-sha> <before-sha>" >&2; exit 2; }

MODE=release
if [ "${1:-}" = "--pre" ]; then MODE=pre; shift; fi
SHA="${1:-}"; [ -n "$SHA" ] || usage
SHA="$(git rev-parse --verify "$SHA^{commit}")"

# Turn legacy release/ branches into tags (once), then delete the branches.
migrate_branches() {
  local b tag
  while read -r b; do
    [ -n "$b" ] || continue
    tag="${b#release/}"
    if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
      run git tag "$tag" "$REMOTE/$b"
      run git push -q "$REMOTE" "refs/tags/$tag"
      say "- Converted branch $b → tag $tag"
    fi
    run git push -q "$REMOTE" --delete "$b"
  done < <(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE/release/" \
             | grep -E "^release/(pre-)?v$SEMVER$" || true)
}

# Release tags (vX.Y.Z only; pre- tags excluded) pointing at a commit.
releases_at() { git tag --points-at "$1" | grep -E "^v$SEMVER$" || true; }

# Sets: latest, next, bump. Fails if the latest release isn't an ancestor of $SHA.
compute_version() {
  latest="$(git tag -l 'v*' | sed -nE "s/^v($SEMVER)$/\1/p" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  if [ -z "$latest" ]; then
    next="1.0.0"; bump="first release"; return
  fi
  local base="v$latest" major minor patch feat_merged feat_live=0 b
  if ! git merge-base --is-ancestor "$base" "$SHA"; then
    echo "::error::$base is not an ancestor of ${SHA:0:7}; refusing to version a diverged prod." >&2
    exit 1
  fi
  IFS=. read -r major minor patch <<< "$latest"
  # feat/ work since the last release: merge-commit subjects ("Merge branch 'feat/x'") and live
  # feat/ branches that are new in this release.
  feat_merged="$(git log --merges --format='%s' "$base..$SHA" | grep -cE "(^|[ '/])feat/" || true)"
  while read -r b; do
    [ -n "$b" ] || continue
    if git merge-base --is-ancestor "$REMOTE/$b" "$SHA" && ! git merge-base --is-ancestor "$REMOTE/$b" "$base"; then
      feat_live=$((feat_live + 1))
    fi
  done < <(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE/feat/")
  if [ "$feat_merged" -gt 0 ] || [ "$feat_live" -gt 0 ]; then
    next="$major.$((minor + 1)).0"; bump="minor (feat/ included)"
  else
    next="$major.$minor.$((patch + 1))"; bump="patch (fixes only)"
  fi
}

prev_label() { [ -n "$latest" ] && echo "v$latest" || echo none; }

migrate_branches

# ── --pre: rollback point before the deploy ──────────────────────────────────────────────
if [ "$MODE" = pre ]; then
  BEFORE="${2:-}"; [ -n "$BEFORE" ] || usage
  if ! BEFORE="$(git rev-parse --verify --quiet "$BEFORE^{commit}")"; then
    say "No previous prod commit for this run (first push or manual run). No pre-release tag."
    exit 0
  fi
  if [ -n "$(releases_at "$SHA")" ]; then
    say "${SHA:0:7} is already released ($(releases_at "$SHA")). No pre-release tag."
    exit 0
  fi
  compute_version
  pre="pre-v$next"
  if git rev-parse --verify --quiet "refs/tags/$pre" >/dev/null; then
    say "Tag $pre already exists. Kept as is."
    exit 0
  fi
  say "### Pre-release tag $pre"
  say "- Rollback point: \`${BEFORE:0:7}\` (prod before this deploy)"
  say "- Deploying: \`${SHA:0:7}\` → will become v$next if the health check passes"
  say "- Previous release: $(prev_label)"
  run git tag "$pre" "$BEFORE"
  run git push -q "$REMOTE" "refs/tags/$pre"
  exit 0
fi

# ── release: after a healthy deploy ──────────────────────────────────────────────────────
existing="$(releases_at "$SHA")"
if [ -n "$existing" ]; then
  say "Release already exists for ${SHA:0:7}: $existing. Nothing to do."
  run git push -q "$REMOTE" "$SHA:refs/heads/release"
  exit 0
fi
compute_version
tag="v$next"
say "### Release $tag"
say "- Commit: \`${SHA:0:7}\`"
say "- Previous: $(prev_label)"
say "- Bump: $bump"
if git rev-parse --verify --quiet "refs/tags/pre-$tag" >/dev/null; then
  say "- Rollback point: pre-$tag"
fi

# What this release contains: the work branches and PRs merged since the previous release.
range="$SHA"; [ -n "$latest" ] && range="v$latest..$SHA"
subjects="$(git log --merges --format='%s' "$range")"
merged="$(grep -oE "(feat|fix|hotfix)/[A-Za-z0-9._-]+" <<<"$subjects" | sort -u | xargs || true)"
prs="$(sed -nE 's/^Merge pull request #([0-9]+) from [^/]+\/(merge\/prod-[^ ]+).*$/#\1 (\2)/p' <<<"$subjects" | xargs || true)"
say "- Merged branches: ${merged:-none}"
say "- Prod PRs: ${prs:-none}"
run git tag "$tag" "$SHA"
run git push -q "$REMOTE" "refs/tags/$tag"
# `release` always points at what is live (fast-forward; created on the first run).
run git push -q "$REMOTE" "$SHA:refs/heads/release"
say "- Branch \`release\` → \`${SHA:0:7}\`"

# Work branches fully contained in the new release → delete. Anything not contained is kept.
deleted=() kept=()
while read -r b; do
  [ -n "$b" ] || continue
  if git merge-base --is-ancestor "$REMOTE/$b" "$SHA"; then deleted+=("$b"); else kept+=("$b"); fi
done < <(git for-each-ref --format='%(refname:strip=3)' \
  "refs/remotes/$REMOTE/feat/" "refs/remotes/$REMOTE/fix/" "refs/remotes/$REMOTE/hotfix/")

if [ "${#deleted[@]}" -gt 0 ]; then
  run git push -q "$REMOTE" --delete "${deleted[@]}"
  say "- Deleted (included in $tag): ${deleted[*]}"
else
  say "- Deleted: none"
fi
say "- Kept (not released yet): ${kept[*]:-none}"

# Release notes on GitHub: a Release for the tag and a comment on the prod PR that shipped it.
if [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null; then
  notes="**$tag** — $bump, deployed and health-checked.

| | |
|---|---|
| Commit | \`${SHA:0:7}\` |
| Previous release | $(prev_label) |
| Rollback point | $(git rev-parse --verify --quiet "refs/tags/pre-$tag" >/dev/null && echo "pre-$tag" || echo "$(prev_label)") |
| Merged branches | $(sed 's/ /, /g' <<<"${merged:-none}") |
| Prod PRs | ${prs:-none} |"
  run gh release create "$tag" --verify-tag --title "$tag" --notes "$notes" \
    || echo "::warning::Could not create the GitHub Release for $tag"
  pr="$(git log -1 --format='%s' "$SHA" | sed -nE 's/^Merge pull request #([0-9]+) .*/\1/p')"
  if [ -n "$pr" ]; then
    run gh pr comment "$pr" --body "Released as $tag.

$notes" || echo "::warning::Could not comment on PR #$pr"
  fi
fi
