#!/usr/bin/env bash
# Install this fork's local guardrails. Idempotent — run once per clone
# (`just ralim-setup`), re-run any time. See ralim/README.md.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

UPSTREAM_SLUG="ethereum-optimism/optimism"
FORK_SLUG="Lambda256/optimism-ralim"
# Deliberately not a valid URL: `git push upstream` must fail loudly.
BLOCKED_PUSH_URL="DISABLED-no-pushing-to-${UPSTREAM_SLUG}"

# Git hooks. Fork-owned directory, not upstream's .githooks/: the guard must
# survive base-tag changes, and older tags have no .githooks/ at all. Our
# pre-push chains to upstream's hook when the current base ships one.
git config core.hooksPath ralim/githooks
echo "✓ core.hooksPath -> ralim/githooks"

# Break the push side of the upstream remote; the fetch URL stays intact so
# `just ralim-sync` keeps working.
if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url --push upstream "$BLOCKED_PUSH_URL"
  echo "✓ upstream push URL disabled (fetch URL untouched)"
else
  echo "! no 'upstream' remote — add it with:"
  echo "    git remote add upstream https://github.com/${UPSTREAM_SLUG}.git"
  echo "    ./ralim/setup-clone.sh"
fi

# A bare `git push` goes to the fork, whatever branch is checked out.
git config remote.pushDefault origin
echo "✓ remote.pushDefault -> origin"

# `gh pr create` on a fork defaults to the PARENT repo. Point it at the fork
# instead — equivalent to `gh repo set-default ${FORK_SLUG}`.
git config remote.origin.gh-resolved base
echo "✓ gh default repo -> ${FORK_SLUG}"

echo
echo "Fork policy: all PRs target ${FORK_SLUG}, base branch 'ralim'."
echo "Never push or open a PR to ${UPSTREAM_SLUG}. See ralim/README.md."
