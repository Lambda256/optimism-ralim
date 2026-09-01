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
`op-reth/v2.3.3`). Fork-owned code lives in `ralim/` and `rust/ralim/`.

What the stack currently touches outside those directories, and why each one has
to be there:

| File | Why |
| ---- | --- |
| `AGENTS.md` | The fork notice at the top; `CLAUDE.md` symlinks to it. Agents must see the policy before touching git. |
| `rust/Cargo.toml` | Workspace members, the dependency entries the vendored crates' manifests expect, and the two `[patch]` entries (rate limiter, musl fix). |
| `rust/rustfmt.toml` | `ignore = ["ralim/vendor"]`, so our formatter leaves the vendored upstream crates byte-identical. |
| `rust/op-reth/crates/node/src/args.rs` | The `--rollup.download-rate-limit-mbps` flag on `RollupArgs`, which is where op-reth's CLI is defined. |
| `rust/op-reth/crates/node/src/proof_history.rs` | Installs the limiter in `launch_node`, before the node builds its pipeline. |
| `rust/op-reth/crates/node/Cargo.toml` | The dependency for the two files above. |

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

If the new tag moves the pinned reth revision, re-vendor afterwards — see
[After a tag bump that moves the reth pin](#after-a-tag-bump-that-moves-the-reth-pin).

## P2P download rate limiting

`--rollup.download-rate-limit-mbps <MEGABYTES_PER_SEC>` caps how fast op-reth
pulls block data over devp2p. Unset, or `0`, leaves it unbounded — upstream's
behaviour.

```bash
op-reth node --rollup.download-rate-limit-mbps 20     # ~20 MB/s
op-reth node --rollup.download-rate-limit-mbps 2.5    # fractional is fine
```

Details worth knowing before you set it:

- **Global, not per peer.** One token bucket for the whole process, shared by the
  header and body downloaders and every peer they fan out to. The knob is a cap
  on what this host pulls, so that is the unit that makes sense.
- **Decimal megabytes** — 1 MB/s = 1,000,000 bytes/s. Internally the flag is
  stored as bytes per second (`RollupArgs` derives `Eq`, which `f64` does not
  implement).
- **RLP bytes, pre-compression.** Charging uses the RLP-encoded size of each
  response, measured before RLPx applies snappy, so real socket throughput ends
  up somewhat *below* the number you set.
- **Burst is one second of traffic**, floored at 8 MiB so a single large bodies
  response is never bigger than the bucket.
- **It throttles catch-up itself.** A node that is behind stays behind longer.
  This is a knob for bounding bandwidth cost, not for syncing faster.

### What it does and does not cover

reth hands one `FetchClient` to two consumers
(`reth-node-builder`'s `launch/engine.rs`):

| Consumer | Used when | Limited? |
| -------- | --------- | -------- |
| Staged pipeline (`reth-downloaders`) | Backfill — the node is far enough behind to run the pipeline | **Yes** |
| Engine block downloader | Live sync filling a small gap | No |
| Transaction gossip | Always | No |

So this covers the case it was built for — a backlogged chain catching up — and
not the engine's live gap fills. Covering those too means wrapping the client in
`launch/engine.rs`, which would mean vendoring `reth-node-builder` (7,700 lines)
instead of `reth-downloaders` (5,400).

Nothing here touches op-node: its P2P is gossip plus a req/resp *server*, and the
req/resp sync client was removed upstream, so op-node is not on the catch-up
download path at all.

### How it is wired in

The limiter itself is a fork-owned crate,
[`rust/ralim/p2p-ratelimit`](../rust/ralim/p2p-ratelimit): a token bucket, a
process-global `OnceLock`, and `RateLimitedClient`, a decorator over reth's
`HeadersClient`/`BodiesClient` that charges each response and waits out the
deficit.

Applying it needs a change inside upstream code, because reth builds the
downloaders itself and exposes no hook. That change is kept as small as possible:

1. [`rust/ralim/vendor/reth-downloaders`](../rust/ralim/vendor/reth-downloaders)
   is a copy of the crate at the reth revision the base tag pins, carrying a
   91-line diff — the two downloader builders wrap their client in
   `RateLimitedClient`, plus manifest edits. The diff is the source of truth and
   lives in [`ralim/patches/reth-downloaders.patch`](patches/reth-downloaders.patch).
2. `[patch."<reth url>"]` in `rust/Cargo.toml` redirects every dependent —
   including upstream's own `reth-node-builder` — to that copy.

**The failure mode to know about:** if the `[patch]` key stops matching the
pinned reth source URL, cargo does not error. It prints `Patch ... was not used
in the crate graph` and builds against the unpatched upstream crate, and the rate
limiter silently disappears. A base-tag change can do exactly that — the URL is
`paradigmxyz/reth` at `op-reth/v2.3.3` but `op-rs/reth` on `develop`. So:

```bash
./ralim/check-patches.sh     # asserts the patch is live in the crate graph
```

The `pre-push` hook runs it whenever a push touches `rust/Cargo.toml` or
`rust/ralim/`.

### After a tag bump that moves the reth pin

Every vendored copy must match the reth version the rest of the workspace builds
against — `./ralim/vendor-reth-crate.sh --list` names them:

```bash
./ralim/vendor-reth-crate.sh reth-downloaders   # re-vendor from the new pin, re-apply the patch
./ralim/vendor-reth-crate.sh reth-tasks
./ralim/check-patches.sh
cd rust && cargo check -p reth-downloaders -p reth-tasks -p reth-optimism-node
```

The script reads the pin (URL plus tag or rev) straight out of `rust/Cargo.toml`,
so it follows the base tag automatically. If a patch stops applying, resolve the
`.rej` files and record the result with
`./ralim/vendor-reth-crate.sh <crate> --save-patch`.

Watch for one failure mode that is not a conflict: a vendored crate's manifest
inherits `.workspace = true` from *reth's* workspace, not ours, so a feature reth
enables and we do not shows up as a compile error in the vendored copy rather
than a patch rejection. `reth-tasks` needed `tracing = { workspace = true,
features = ["attributes"] }` for exactly this reason.

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

## The musl fix in `rust/ralim/vendor/reth-tasks`

Upstream reth does not support musl targets. `reth-tasks` initializes
`libc::sched_param` with only `sched_priority`, which is glibc's whole struct but
not musl's — musl also carries the POSIX sporadic-server fields, so the literal
fails to compile and takes every musl build of op-reth down with it. Upstream
`main` still has it, so no tag bump fixes this.

The vendored copy zeroes the struct instead, which is what glibc's one-field
literal amounted to. That is the entire change; it is the price of
[static builds](STATIC-BUILD.md), and it has to be re-vendored on every reth pin
move like the rate limiter does.

## Static `op-reth` builds

```bash
./ralim/build-static-opreth.sh     # → ralim/dist/op-reth-x86_64-unknown-linux-musl
```

Cross-compiles `op-reth` to musl inside a container, so the result has no
`PT_INTERP` at all and runs on a Rocky Linux host whatever its glibc, with no
container runtime. The build host needs only docker or podman. Run it *on* the
x86_64 target box and the builder is native there — no emulation.

[`STATIC-BUILD.md`](STATIC-BUILD.md) covers why "static" has to mean musl, why
the build host has to be glibc even though the output is musl (bindgen `dlopen`s
libclang from a build script), why Rocky cannot supply the toolchain itself, and
what changes at run time (musl's resolver, ulimits).

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
