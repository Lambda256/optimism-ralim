#!/usr/bin/env bash
# Keep the develop mirror in sync with ethereum-optimism/optimism:
# upstream/develop -> local develop (fast-forward only) -> origin/develop.
# Nothing here ever pushes to upstream, and nothing here touches ralim.
#
# ralim is a *tag-based* patch branch: it is moved forward by rebasing onto a new
# release tag, never by merging develop. Use ./ralim/rebase-new-tag.sh for that.
# See ralim/README.md.
#
# Usage: ./ralim/sync-upstream.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ "${1-}" = "--merge" ]; then
  cat >&2 <<-MSG
	--merge is gone. Merging develop into ralim would drag every post-tag commit
	into the patch stack; ralim advances only by rebasing onto a new release tag:

	    ./ralim/rebase-new-tag.sh v2.4.2
	MSG
  exit 2
elif [ $# -gt 0 ]; then
  echo "usage: $0" >&2
  exit 2
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "no 'upstream' remote — add it with:" >&2
  echo "  git remote add upstream https://github.com/ethereum-optimism/optimism.git" >&2
  exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "working tree has uncommitted changes — commit or stash first." >&2
  exit 1
fi

starting_branch=$(git rev-parse --abbrev-ref HEAD)

echo "==> fetching upstream (tags included, so release tags are available)"
# Output is captured because the monorepo's .gitmodules trips harmless
# multi-config warnings on old refs; it is shown only if the fetch fails.
if ! fetch_out="$(git fetch upstream develop --tags --prune 2>&1)"; then
  printf '%s\n' "$fetch_out" >&2
  echo "fetch failed." >&2
  exit 1
fi

echo "==> fast-forwarding develop"
if [ "$starting_branch" = "develop" ]; then
  # --ff-only: a merge commit on develop would mean it is no longer a mirror.
  git merge --ff-only upstream/develop
else
  # Refuses to move develop non-fast-forward, which is exactly what we want.
  if ! git fetch upstream develop:develop; then
    echo >&2
    echo "develop could not be fast-forwarded — it has local commits." >&2
    echo "Move them to ralim, then reset: git branch -f develop upstream/develop" >&2
    exit 1
  fi
fi

echo "==> pushing develop to origin"
git push origin develop:develop

base_sha="$(git merge-base ralim upstream/develop 2>/dev/null || true)"
if [ -n "$base_sha" ]; then
  base_tag="$(git describe --tags --exact-match "$base_sha" 2>/dev/null || echo "$(git rev-parse --short "$base_sha") (untagged)")"
  behind="$(git rev-list --count "$base_sha..upstream/develop")"
  echo
  echo "develop is in sync. ralim is based on $base_tag, $behind commit(s) behind develop."
  echo "Newest release tags:"
  git tag -l 'op-reth/v*' --sort=-v:refname | head -3 | sed 's/^/  /'
  echo "Move ralim to one with: ./ralim/rebase-new-tag.sh <tag>"
fi
