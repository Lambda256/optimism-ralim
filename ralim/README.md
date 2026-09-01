# Lambda256 `optimism-ralim` fork

This repository is Lambda256's fork of
[`ethereum-optimism/optimism`](https://github.com/ethereum-optimism/optimism).
It exists to carry Lambda256-specific changes (starting with op-reth P2P
download rate limiting), not to contribute back upstream.

## Branch model

| Branch    | Role                                                                                                                                                                                           |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ralim`   | **Default branch.** A *tag-based patch branch*: an upstream release tag plus Lambda256 commits on top. Moved forward only by **rebasing onto a newer tag** — never by merging `develop`.       |
| `develop` | **Pristine upstream mirror.** Only ever fast-forwarded from `upstream/develop`. Never commit to it, never merge `ralim` into it. It exists so tags and upstream history are available locally. |

**Current base: `op-reth/v2.3.3`.** Never stored in a config file — it is derived
from the repo, since the patch branch forks off upstream history at exactly its
base commit:

```bash
git describe --tags --exact-match "$(git merge-base ralim upstream/develop)"
```

```text
   op-reth/v2.3.3 ── ralim patches ──▶ ralim (default)   ← rebase-new-tag.sh moves this
        │
upstream/develop ──fast-forward──▶ develop (mirror)
```

Feature branches are cut from `ralim` and PR'd back into `ralim`. Nothing ever
flows out to upstream.

### Why tag-based instead of tracking `develop`

`develop` moves dozens of commits a day and is not a release. Pinning to
`op-reth/vX.Y.Z` means the fork always sits on a tested release, and upgrades
happen deliberately, one tag at a time, with the patch stack replayed on top.

The corollary: **keep the patch stack out of upstream-owned files.** Every
upstream file a patch touches is a conflict waiting for the next tag bump — and
files can be missing entirely on another tag (`.githooks/` did not exist at
`op-reth/v2.3.3`). Fork-owned files live in `ralim/`. Right now the stack touches
exactly one upstream file: a notice at the top of `AGENTS.md` (`CLAUDE.md`
symlinks to it), which agents must see before they touch git.

## Moving to a new tag

```bash
./ralim/rebase-new-tag.sh v2.4.2                  # short for op-reth/v2.4.2
./ralim/rebase-new-tag.sh v2.4.2 --verify-build    # also cargo check / go build
./ralim/rebase-new-tag.sh v2.4.2 --push            # force-with-lease to origin
./ralim/rebase-new-tag.sh --help
```

[`rebase-new-tag.sh`](rebase-new-tag.sh) fetches tags, derives the current base
via `git merge-base`, writes a backup ref (`refs/fork-backup/ralim-<timestamp>`)
so the whole run can be undone with one `git update-ref`, fast-forwards the
`develop` mirror, then replays the patch stack onto the new tag. It refuses to
run on a dirty tree or with a rebase already in progress, and asks before moving
the stack sideways or backwards (`--yes` to skip that prompt).

Conflicts are left in progress on purpose, with the resolution commands printed.
`rust/Cargo.lock` is the exception: it is generated, so the script takes the new
base's copy and re-locks with cargo instead of hand-merging.

Verification is fmt-only by default, because a cold `cargo check` of this
workspace takes many minutes:

- Rust changes in the stack → the repo's own `just fmt-check-all` in `rust/`
- Go changes in the stack → `gofmt -l` on the touched directories
- `--verify-build` adds `cargo check --workspace` / `go build ./...`
- `--no-verify` skips all of it

A rebase rewrites history, so `ralim` is force-pushed. Teammates recover with
`git fetch origin && git rebase origin/ralim`.

## Syncing the mirror

```bash
./ralim/sync-upstream.sh    # upstream/develop -> develop -> origin/develop
```

Fast-forward only; it fails loudly if `develop` ever acquires local commits. It
also reports how far the current base tag is behind `develop` and lists the
newest release tags. It deliberately does **not** touch `ralim` — that is
`rebase-new-tag.sh`'s job.

## No PRs to upstream — ever

Do not open pull requests against `ethereum-optimism/optimism` from this fork,
and do not push branches to it. Every PR targets `Lambda256/optimism-ralim`,
base branch `ralim`.

The rule is enforced in three independent layers, all installed by
[`setup-clone.sh`](setup-clone.sh):

1. **Push URL** — `upstream`'s *push* URL is set to an invalid placeholder, so
   `git push upstream …` fails while `git fetch upstream` keeps working.
2. **`pre-push` hook** — [`githooks/pre-push`](githooks/pre-push) rejects any push
   whose remote name or URL points at `ethereum-optimism`, then chains to
   upstream's own `.githooks/pre-push` when the current base tag ships one.
   `core.hooksPath` points at `ralim/githooks`, not `.githooks`, so the guard
   survives every tag change.
3. **`gh` default repo** — `remote.origin.gh-resolved=base` makes `gh pr create`
   (and the rest of `gh pr`) target this fork instead of the parent, which is
   `gh`'s default for a fork.

For AI agents there is a fourth layer: a Claude Code `PreToolUse` hook
([`hooks/block-upstream-pr.py`](hooks/block-upstream-pr.py), wired up in
[`.claude/settings.json`](../.claude/settings.json)) blocks any shell command that
would push to, or open/modify a PR on, `ethereum-optimism/optimism`. Read-only
`gh` commands against upstream stay allowed — reading upstream issues and PRs is
still useful. Its cases live in
[`hooks/test-block-upstream-pr.py`](hooks/test-block-upstream-pr.py) — run
`python3 ralim/hooks/test-block-upstream-pr.py` after touching the hook.

None of this is enforceable on GitHub's side: a fork can always open a PR to its
parent through the web UI, and only GitHub Support can detach a fork from its
parent. Treat the layers above as guardrails against accident, and the policy in
this file as the actual rule.

## Setup, once per clone

```bash
./ralim/setup-clone.sh
```

Idempotent. Installs the hooks (`core.hooksPath` → `ralim/githooks`) and the
local config that keeps pushes and PRs away from upstream. It replaces
`just install-git-hooks`.

These are plain scripts rather than `justfile` recipes on purpose: a recipe would
mean patching the upstream `justfile` on every tag, and the recipe it anchored to
does not exist on all tags.

## Upstream docs

[`CLAUDE.md`](../CLAUDE.md) / [`AGENTS.md`](../AGENTS.md) and `docs/ai/` are
upstream's and describe upstream's workflow — in particular "Before Opening a
PR", which still applies to PRs targeting `ralim`. Where they say `develop`, read
`ralim`.
