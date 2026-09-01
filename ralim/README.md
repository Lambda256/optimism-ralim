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

| File                                            | Why                                                                                                                                      |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `AGENTS.md`                                     | The fork notice at the top; `CLAUDE.md` symlinks to it. Agents must see the policy before touching git.                                  |
| `rust/Cargo.toml`                               | Workspace members, the dependency entries the vendored crates' manifests expect, and the two `[patch]` entries (rate limiter, musl fix). |
| `rust/rustfmt.toml`                             | `ignore = ["ralim/vendor"]`, so our formatter leaves the vendored upstream crates byte-identical.                                        |
| `rust/op-reth/crates/node/src/args.rs`          | The `--rollup.download-rate-limit-mbps` flag on `RollupArgs`, which is where op-reth's CLI is defined.                                   |
| `rust/op-reth/crates/node/src/proof_history.rs` | Installs the limiter in `launch_node`, before the node builds its pipeline.                                                              |
| `rust/op-reth/crates/node/Cargo.toml`           | The dependency for the two files above.                                                                                                  |

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
- **It does not reduce a cloud bill.** Download is ingress, and ingress is free
  on the major clouds. The billed direction is upload — see
  [Upload (egress) limiting](#upload-egress-limiting--do-it-in-the-kernel).

### What it does and does not cover

reth hands one `FetchClient` to two consumers
(`reth-node-builder`'s `launch/engine.rs`):

| Consumer                             | Used when                                                    | Limited? |
| ------------------------------------ | ------------------------------------------------------------ | -------- |
| Staged pipeline (`reth-downloaders`) | Backfill — the node is far enough behind to run the pipeline | **Yes**  |
| Engine block downloader              | Live sync filling a small gap                                | No       |
| Transaction gossip                   | Always                                                       | No       |

So this covers the case it was built for — a backlogged chain catching up — and
not the engine's live gap fills. Covering those too means wrapping the client in
`launch/engine.rs`, which would mean vendoring `reth-node-builder` (7,700 lines)
instead of `reth-downloaders` (5,400).

Nothing here touches op-node: its P2P is gossip plus a req/resp *server*, and the
req/resp sync client was removed upstream, so op-node is not on the catch-up
download path at all.

### Why not in the kernel, the way upload is

Fair question, and the answer is not "it was impossible". The kernel *can* limit
ingress — either `tc` policing on the ingress qdisc, or the cleaner form, an `ifb`
device fed by `mirred` with a real shaper on it:

```bash
ip link add ifb0 type ifb && ip link set ifb0 up
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: u32 match u32 0 0 \
    action mirred egress redirect dev ifb0
tc qdisc add dev ifb0 root tbf rate 50mbit burst 256kbit latency 50ms
```

If the goal were only "keep total ingress under N Mbit/s", that is the whole job:
no vendored crate, no `[patch]`, nothing to re-apply on a tag bump. Three things
make the kernel the wrong tool for *this* limit, and the first is decisive.

**1. Throttling ingress in the kernel makes us drop honest peers.** reth puts a
deadline on every in-flight request, and `reth-network`'s `session/active.rs` is
explicit about what happens when one is missed:

> If a request misses the `protocol_breach_request_timeout` then this session is
> considered in protocol violation and will close.

A kernel shaper works by slowing responses *that we already asked for*, so it
walks straight into that timer: the tighter the cap, the more of our own requests
time out and the more good peers we terminate. The in-client limiter instead
reduces how many requests we *issue*, so there is nothing in flight to time out.

This is the exact mirror of the upload case. Throttle serving in the client and
**the peer drops us**; throttle downloading in the kernel and **we drop the
peer**. Each direction has one side of the connection that can afford to wait,
and it is not the same side.

**2. A port filter cannot separate backfill from gossip.** devp2p multiplexes
every capability over a single RLPx connection per peer, so header and body
responses share one TCP session with transaction gossip, and discovery shares the
port. `tc` classifies by address and port, which means shaping devp2p at all
means shaping all of it — including the tx gossip a sequencer-adjacent node needs
promptly. The in-client limiter sits on the pipeline's downloader specifically.

**3. It needs privileges the deployment may not grant.** `tc` wants root or
`CAP_NET_ADMIN`, and inside the right network namespace. Many Kubernetes setups
will not give a node pod either. A CLI flag is configured per node, shows up in
the node's own logs, and needs no host access.

The two directions, side by side:

|                                | Download                                                          | Upload                            |
| ------------------------------ | ----------------------------------------------------------------- | --------------------------------- |
| Kernel can do it?              | Yes — ingress policing or `ifb`                                   | Yes, and it is `tc`'s native job  |
| Cost of doing it in the kernel | We time out and drop peers; no selectivity; needs `CAP_NET_ADMIN` | None worth noting                 |
| Cost of doing it in the client | None — fewer requests, nothing to time out                        | Peers drop us; 24,230-line vendor |
| Which direction is billed      | Ingress, i.e. free                                                | Egress, i.e. billed               |
| What this fork does            | In-client flag                                                    | `tc` on the host                  |

Worth being blunt about the trade: what the vendoring below buys is points 1-3,
not the cap itself. A deployment that only needs a coarse ceiling on total
ingress, and can spare the peers, does not need any of it.

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
for crate in $(./ralim/vendor-reth-crate.sh --list); do
  ./ralim/vendor-reth-crate.sh "$crate"   # re-vendor from the new pin, re-apply the patch
done
./ralim/check-patches.sh
cd rust && cargo check -p reth-downloaders -p reth-tasks -p reth-db -p reth-optimism-node
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

For the same reason a vendored crate is linted by *our* `[workspace.lints]`, which
are stricter than reth's: `reth-db` trips `unnameable-types`. It is `warn`, so it
does not fail a build, but it would fail a `-D warnings` run.

## Upload (egress) limiting — do it in the kernel

**Recommendation: shape egress with `tc` on the host, not in op-reth or op-node.**
The reasons are below, but the short version is that the kernel gets this right
for a one-line command and the client-side version costs a 24,000-line vendored
crate plus a standing risk of peers penalising us.

### Why this is the side that costs money

Cloud bandwidth pricing is asymmetric: **ingress is free, egress is billed.** The
download limiter bounds saturation and lets a node be a polite neighbour, but it
does not move the invoice. What the node *serves* does.

And the exposure is real: a single peer running a full backfill against us pulls
tens of gigabytes, and nothing rate-limits it.

### Nothing in the stack limits upload today

| Path                       | What bounds it                    | Rate limited?         |
| -------------------------- | --------------------------------- | --------------------- |
| op-reth request serving    | 2 MiB and 1024 items per response | **No**                |
| op-reth transaction gossip | per-message soft size limits      | No                    |
| op-node req/resp server    | 20 req/s global, 4 req/s per peer | By request count only |
| op-node gossip forwarding  | mesh degree `D` (default 8)       | No                    |

The op-reth serving path is `reth-network`'s `eth_requests.rs`: it caps each
*response* (`SOFT_RESPONSE_LIMIT` = 2 MiB, `MAX_HEADERS/BODIES/RECEIPTS_SERVE` =
1024) and nothing else. There is no cap on requests per second, so a peer issuing
them back to back pulls data at whatever rate the link allows.

op-node is better off: its payload server does hold token buckets
([op-node/p2p/sync.go:40-46](../op-node/p2p/sync.go#L40-L46)), but they count
*requests*, never bytes, and the values are hardcoded with no CLI. Its gossip
forwarding multiplies every block it receives by the mesh degree
([op-node/p2p/gossip.go:42](../op-node/p2p/gossip.go#L42)) — modest per block, but
it is pure egress.

### The kernel is the right place

Three reasons it beats an application-level limiter, in order of importance:

1. **It shapes the bytes you are billed for.** `tc` works on real wire bytes —
   after RLPx's snappy compression, including TCP/IP overhead. An in-client
   limiter counts RLP bytes before compression, so it can never agree with the
   invoice. (Our download limiter has exactly this imprecision.)
2. **It covers *all* egress, not just P2P.** RPC responses, metrics scrapes, log
   shipping. The bill does not care which socket the bytes left through.
3. **It costs nothing to maintain.** No vendored crate, no `[patch]`, nothing to
   re-apply on a tag bump, no risk of a silent regression.

#### Whole interface, simplest form

```bash
# Cap all egress on eth0 at 50 Mbit/s
sudo tc qdisc add dev eth0 root tbf rate 50mbit burst 256kbit latency 50ms

sudo tc -s qdisc show dev eth0   # verify; watch the "dropped"/"backlog" counters
sudo tc qdisc del dev eth0 root  # undo
```

`burst` must be at least `rate / HZ`, or the shaper never reaches the target rate
— 256 kbit is comfortable at 50 Mbit/s. Note this also shapes SSH and RPC on that
interface; if you need to stay reachable under load, use the port-scoped form.

#### Port-scoped, so only P2P is shaped

Leaves SSH, RPC, and metrics at line rate. Ports are the defaults: op-reth devp2p
on 30303 (TCP and UDP), op-node libp2p on 9222.

```bash
IF=eth0
sudo tc qdisc add dev $IF root handle 1: htb default 10
sudo tc class add dev $IF parent 1:  classid 1:1  htb rate 1000mbit
sudo tc class add dev $IF parent 1:1 classid 1:10 htb rate 1000mbit ceil 1000mbit  # everything else
sudo tc class add dev $IF parent 1:1 classid 1:20 htb rate 50mbit   ceil 50mbit    # P2P

for port in 30303 9222; do
  sudo tc filter add dev $IF protocol ip parent 1:0 prio 1 u32 \
      match ip sport "$port" 0xffff flowid 1:20
done
```

Set the `1000mbit` figures to the link's actual speed — HTB borrows against the
parent class, so a root rate below the real capacity throttles everything, and one
far above it makes the classes meaningless. `default 10` is what unclassified
traffic falls into.

`match ip sport` reads the source-port field, which sits at the same offset for
TCP and UDP, so one rule covers devp2p's TCP sessions and discovery's UDP
datagrams. IPv6 needs its own rules (`protocol ipv6 … match ip6 sport`).

#### Operational notes

- **Not persistent.** `tc` state is lost on reboot — put it in a systemd unit
  (`ExecStart=/sbin/tc …`, `Type=oneshot`, `RemainAfterExit=yes`) or your network
  configuration.
- **Containers have their own netns.** If the node runs in Docker, apply this
  inside the container's namespace or on its `veth` on the host, not on the host
  bridge.
- **Egress only.** That is what we want; ingress shaping would need an `ifb`
  device and policing, and ingress is the free direction anyway.
- **Measure at the source of truth** — `tc -s qdisc show` plus the cloud's own
  egress metric. Client-side counters will not match.

### Knobs you already have, no code required

Worth setting alongside the shaper, because they bound *who* can pull from you
rather than how fast:

| Knob                                | Default | What it does                            |
| ----------------------------------- | ------- | --------------------------------------- |
| op-reth `--max-inbound-peers N`     | 30      | How many peers may request data from us |
| op-node `--p2p.sync.req-resp=false` | on      | Turns off the CL payload server         |
| op-node `--p2p.peers.hi` / `.lo`    | 30 / 20 | Same idea on the CL side                |
| op-node `--p2p.gossip.mesh.d`       | 8       | Peers each received block is sent on to |

`--max-inbound-peers` is the bluntest and most effective of the four. Turning off
the CL payload server costs nothing in the long run — upstream plans to remove it
in favour of EL P2P sync. Lower the gossip mesh degree only deliberately: it is a
direct multiplier on gossip egress, but it also weakens the mesh.

### Why not in the client

Beyond the maintenance cost, there is a correctness trap — the mirror of the one
that kept the download limiter out of the kernel (see
[Why not in the kernel, the way upload is](#why-not-in-the-kernel-the-way-upload-is)).
**Delaying a response gets us punished.** The requesting peer times out on an RTT-derived deadline and
then drops or penalises us, so a byte-rate limiter that works by stalling
responses ends up shrinking our peer set — the opposite of a graceful cap.

The protocol-correct way to shed load is to **serve fewer items**: `eth/68`
permits partial responses, and reth already truncates by `SOFT_RESPONSE_LIMIT`. So
an in-client upload limiter would lower that limit dynamically as the budget
drains, rather than adding sleeps like the download side does.

If it is ever built anyway, the price is known:

|                    | Download (built)      | Upload                      |
| ------------------ | --------------------- | --------------------------- |
| Crate to vendor    | `reth-downloaders`    | `reth-network`              |
| Its size           | 5,383 lines           | **24,230 lines**            |
| New workspace deps | 3                     | **8**                       |
| Patch stability    | two builder callsites | reth's network stack churns |

The eight are `reth-discv4`, `reth-discv5`, `reth-dns-discovery`, `reth-ecies`,
`reth-net-banlist`, `reth-network-types`, `reth-tokio-util` and `socket2`. The
serving code cannot be split out of `reth-network`, so there is no smaller
vendoring target.

There is a much cheaper middle step if the goal is protecting the node rather
than the bill: **expose op-node's existing serve-side token buckets as CLI
flags.** They already exist and are already correct — the values are just
hardcoded ([op-node/p2p/sync.go:40-46](../op-node/p2p/sync.go#L40-L46)). That is
in-tree Go, no vendoring, no `[patch]`, and it bounds CL upload by request rate.

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

## The musl fixes in `rust/ralim/vendor/`

Upstream reth does not support musl targets, and `main` still does not, so no tag
bump fixes any of this. Each break is a place where reth writes a `libc` type as
though glibc's definition were the only one:

| Crate        | What it assumes                                                                                                                                                               | The fix                                                                                                                                                                        |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `reth-tasks` | `libc::sched_param` has one field. glibc's does; musl's also carries the POSIX sporadic-server fields (`sched_ss_low_priority` and friends), so the literal does not compile. | Zero the struct, which is what glibc's one-field literal amounted to.                                                                                                          |
| `reth-db`    | `statfs::f_type` is `i64`, so the ZFS magic number is an `i64` constant. On musl the field is `c_ulong` (u64) and the comparison does not typecheck.                          | Let the constant follow the platform's field type under `cfg(target_env = "musl")`. Casting would be a sign change on one platform or an `unnecessary_cast` lint on the other. |

Both are one-expression changes, and both are the price of
[static builds](STATIC-BUILD.md): they have to be re-vendored on every reth pin
move, like the rate limiter does.

There is no reliable way to grep for the next one — these are not a single
syntactic pattern but "any use of a libc type whose width or signedness differs
between the two libcs". `./ralim/build-static-opreth.sh --check` is what finds
them, in minutes rather than at the end of a full build.

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
