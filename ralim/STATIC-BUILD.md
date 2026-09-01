# Static `op-reth` builds

[`build-static-opreth.sh`](build-static-opreth.sh) produces a single `op-reth`
file with no dynamic dependencies at all — `ldd` reports `not a dynamic
executable` — so it can be dropped onto a Rocky Linux host and run without
matching that host's glibc, and without a container runtime.

```bash
# on the x86_64 Rocky box, in a clone of this fork
./ralim/build-static-opreth.sh
# → ralim/dist/op-reth-x86_64-unknown-linux-musl
```

The build host needs docker or podman and nothing else — no Rust toolchain, no
musl packages (Rocky has none to offer; see below).

## Why static means musl here, not `-static`

Statically linking glibc is not a workable option, whatever `gcc -static`
suggests. glibc resolves hostnames through NSS modules it `dlopen`s at run time;
a statically linked glibc binary either fails outright or silently loses name
resolution. op-reth needs DNS for its dnsdisc bootnodes, so that is not a trade
we can make.

The musl target is the real answer: `crt-static` is on by default for
`*-unknown-linux-musl`, musl's resolver is self-contained, and the linker output
has no `PT_INTERP` segment — which is exactly what the script asserts before it
hands you the binary.

## Why the build host is glibc and only the output is musl

The obvious approach — build natively inside Alpine, where musl *is* the host
libc, so there is no cross-compilation to get wrong — does not work for op-reth.
It was tried here and it fails, for a reason worth writing down:

```
error: failed to run custom build command for `reth-mdbx-sys v2.3.0`
  Unable to find libclang: "the `libclang` shared library at
  /usr/lib/llvm21/lib/libclang.so.21.1.2 could not be opened:
  Dynamic loading not supported"
```

bindgen `dlopen`s libclang, and cargo compiles build scripts for the **host**
triple. On a musl host the build script is therefore itself statically linked,
and musl's static `dlopen` is a stub that always fails. Three crates in
`op-reth`'s graph run bindgen — `reth-mdbx-sys`, `librocksdb-sys` and `libproc`
(via `metrics-process`) — so this is unavoidable. **The build host has to be
glibc.**

Pulling the other way: `rocksdb` is a hard dependency of `reth-provider`
(`rocksdb.workspace = true`, behind no feature gate), so the musl side needs a
C++ compiler *and* a musl-built libstdc++. Debian and Ubuntu's `musl-tools` is C
only — there is no `musl-g++` in either distribution — so plain
`rust:1.94-bookworm` plus `musl-tools` is not enough either.

And Rocky itself supplies neither half. Verified on `rockylinux:9` (9.8, glibc
2.34) with EPEL enabled:

```
$ dnf list available "musl*"
Error: No matching Packages to list
```

What satisfies both constraints at once is cross-rs's musl image,
`ghcr.io/cross-rs/x86_64-unknown-linux-musl:main`: an Ubuntu 24.04 userland (so
build scripts are dynamically linked and bindgen works) carrying a full
musl-cross toolchain — `x86_64-linux-musl-gcc`, `-g++`, and
`/usr/local/x86_64-linux-musl/lib/libstdc++.a` — plus the `libclang.so` bindgen
needs to load. The script layers the workspace's pinned Rust toolchain onto it
and drives plain `cargo`, so `cross` itself is not required on the host.

One thing op-reth does *not* drag in, which helps: no OpenSSL. Nothing in
`op-reth`'s crate graph depends on `openssl-sys`, so there is no vendored-OpenSSL
step to fight.

## What the script does

1. Reads the pinned toolchain channel out of `rust/rust-toolchain.toml`, so the
   builder never drifts from what the workspace expects.
2. Builds `opreth-musl-builder:<channel>-<triple>`: the pinned toolchain (plus
   the musl target's `std`) from `rust:<channel>-bookworm`, copied onto
   cross-rs's musl image. The context is a scratch directory, so none of the repo
   is uploaded to the daemon.
3. Runs `cargo build --locked --bin op-reth --target <triple>` in that image with
   the repo mounted at `/src`, and with `CARGO_TARGET_*_LINKER`, `CC_*`, `CXX_*`,
   `AR_*`, `RANLIB_*` and `BINDGEN_EXTRA_CLANG_ARGS_*` all pointed at the
   musl-cross toolchain and its sysroot — the wiring that has to be consistent
   or one of the C dependencies quietly builds against the wrong libc.
4. Asserts the result has no `PT_INTERP`, then installs it to
   `ralim/dist/op-reth-<triple>`, chowned back to you.

Build state — `CARGO_TARGET_DIR` and `CARGO_HOME` — lives in engine-managed
volumes (`opreth-musl-target-<triple>`, `opreth-musl-cargo`), not on the bind
mount. `--clean` removes them. Three reasons, in order of how badly each bites:

- **rootless podman**, which is the Rocky default, remaps uids: a container
  writing to a bind-mounted `target/` hits `EPERM` unless `--userns=keep-id`
  lines up exactly. A volume sidesteps the mapping entirely.
- **Bind mounts over virtiofs/9p** (Docker Desktop, if you ever build on a
  laptop) are not coherent enough for a build this parallel. Observed here:
  `rustc` missed an `rlib` another `rustc` had just written, and it surfaced as a
  bogus `can't find crate for alloy_primitives` even though the `.rlib` was on
  disk.
- Nothing under the repo ends up root-owned, and a musl build never touches your
  normal `rust/target` cache.

The container also runs with `--security-opt label=disable`, because Rocky
enforces SELinux and would otherwise deny the bind mount outright rather than
relabel it.

Useful flags — see `--help` for the full list:

| flag | for |
| ---- | --- |
| `--profile maxperf` | the profile upstream ships its images with: fat LTO, one codegen unit. Considerably slower and it wants a lot of RAM for the final link. `release` (the default) is thin LTO at `opt-level = 3`. |
| `--ca-cert PATH` | networks that terminate TLS (Zscaler). Without it `apt` and `cargo fetch` fail inside the container with `unknown issuer`. |
| `--engine podman` | Rocky ships podman rather than docker; the script picks whichever is on `PATH`. |
| `--target aarch64-unknown-linux-musl` | an aarch64 *output*. It also sets `JEMALLOC_SYS_WITH_LG_PAGE=16`, matching op-reth's own `Cross.toml`, so the binary does not assume 4K pages. |
| `--no-jemalloc` | only if jemalloc itself refuses to build. musl's allocator is markedly slower under a node's allocation pattern, so this is a fallback, not a tuning knob. |
| `--clean` | drop the cache volumes and exit. |

Features default to the `op-reth` crate's own defaults, which already include
`jemalloc`, `asm-keccak`, `keccak-cache-global`, `js-tracer`, `otlp` and
`reth-optimism-evm/portable`. `--features` adds to that set.

**The builder images are amd64-only**, because that is all cross-rs publishes.
On the x86_64 Rocky box they run natively. On anything else (an arm64 laptop,
say) every `rustc` and `cc` invocation goes through QEMU and a workspace this
size takes hours; the script warns when it detects that.

## Running the result on Rocky

```bash
ldd ./op-reth-x86_64-unknown-linux-musl     # not a dynamic executable
./op-reth-x86_64-unknown-linux-musl --version
```

Two things differ from the container image you were using:

- **Name resolution goes through musl, not glibc.** musl reads
  `/etc/resolv.conf` and `/etc/hosts` and ignores `/etc/nsswitch.conf`
  entirely — so if the host resolves names via SSSD, LDAP or mDNS, op-reth will
  not. Plain DNS is fine, including the large TXT responses dnsdisc needs (musl
  has had TCP fallback since 1.2.4).
- **Ulimits are yours to set now.** Give the process `ulimit -n 65536`, or a
  systemd unit with `LimitNOFILE=`.

## Alternatives, and why they are not the default

- **Build on Rocky against Rocky's glibc** (`rockylinux:9` container, or the host
  toolchain plus `dnf install clang-devel llvm-devel`). Simplest thing that
  works, and the binary is guaranteed compatible with *that* glibc — but it is
  not static, so it is pinned to glibc 2.34 or newer and cannot move to an older
  host.
- **`cross build --target x86_64-unknown-linux-musl`**, from `rust/op-reth`.
  This is the same toolchain image by a shorter route, and `rust/op-reth/Cross.toml`
  already installs clang for bindgen. Two reasons it is not what the script does:
  `cross` mounts the *host's* rustup toolchain, so the Rocky box would need
  rustup and `cargo install cross` on top of a container engine; and adding a
  musl entry to `Cross.toml` means patching an upstream-owned file, which this
  fork pays for at every tag bump (see [README](README.md)).
