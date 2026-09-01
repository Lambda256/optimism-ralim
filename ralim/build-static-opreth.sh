#!/usr/bin/env bash
# Build a fully static (musl-linked) op-reth binary.
#
# Why "static" has to mean musl: statically linking glibc is not a real option —
# glibc resolves hostnames through NSS modules it `dlopen`s at runtime, so a
# `-static` glibc op-reth would either fail or silently lose DNS, which a node
# needs for its dnsdisc bootnodes. The musl target has `crt-static` on by default
# and a self-contained resolver, so the result genuinely has no PT_INTERP: one
# file, `ldd` says "not a dynamic executable", and it does not care that the
# Rocky host ships glibc 2.34.
#
# Why the build host is glibc and only the *output* is musl: op-reth's C
# dependencies impose two requirements that pull in opposite directions.
#
#   1. bindgen (reth-mdbx-sys, librocksdb-sys, libproc) `dlopen`s libclang. A
#      build script is compiled for the *host* triple, so on a musl host it is
#      itself static, and musl's static dlopen is a stub — bindgen dies with
#      "the libclang shared library could not be opened: Dynamic loading not
#      supported". This rules out building natively inside Alpine, however
#      appealing that looks.
#   2. rocksdb is a hard dependency of reth-provider (`rocksdb.workspace = true`,
#      behind no feature gate), so the musl side needs a C++ compiler and a
#      musl-built libstdc++ — which Debian/Ubuntu's `musl-tools` does not ship.
#
# cross-rs's musl image satisfies both: Ubuntu userland (so build scripts are
# dynamic and bindgen works) plus a full musl-cross toolchain including
# x86_64-linux-musl-g++ and libstdc++.a. This script adds the workspace's pinned
# Rust toolchain to it and drives plain cargo, so the only thing the build host
# needs is docker or podman.
#
# Usage:
#   ./ralim/build-static-opreth.sh                        # release, crate default features
#   ./ralim/build-static-opreth.sh --profile maxperf       # what upstream ships; slow, RAM hungry
#   ./ralim/build-static-opreth.sh --no-jemalloc           # drop jemalloc (see --help)
#   ./ralim/build-static-opreth.sh --ca-cert ~/ca.pem      # behind a TLS-inspecting proxy (Zscaler)
#   ./ralim/build-static-opreth.sh --help
set -euo pipefail

TRIPLE="x86_64-unknown-linux-musl"
PROFILE="release"
FEATURES=""
NO_JEMALLOC=0
ENGINE=""
CA_CERT=""
OUT=""
JOBS=""
REBUILD_IMAGE=0
CLEAN=0

usage() {
	# The header comment block, up to the first non-comment line.
	awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
	cat <<'EOF'

Options:
  --target T       x86_64-unknown-linux-musl (default) or aarch64-unknown-linux-musl
  --profile P      cargo profile: release (default), maxperf, profiling, dev
  --features "..." extra cargo features, added to the op-reth crate defaults
                   (jemalloc, otlp, js-tracer, keccak-cache-global, asm-keccak,
                   reth-optimism-evm/portable)
  --no-jemalloc    build with the system (musl) allocator instead of jemalloc.
                   Only for when jemalloc itself fails to build — musl's malloc
                   is markedly slower under a node's allocation pattern.
  --engine E       docker or podman (default: whichever is on PATH)
  --ca-cert PATH   extra CA certificate to trust inside the builder, for
                   networks that terminate TLS (Zscaler et al). Without it `apt`
                   and `cargo fetch` fail with "unknown issuer" on such a network.
  --out PATH       where to write the finished binary
                   (default: ralim/dist/op-reth-<triple>)
  --jobs N         cargo build jobs (default: container default)
  --rebuild-image  rebuild the builder image even if it already exists
  --clean          delete this build's cache volumes, then exit
  -h, --help       this text

The builder images are amd64-only, because that is all cross-rs publishes. On an
x86_64 build host they run natively; anywhere else they run under emulation, and
a workspace this size then takes hours.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--target) TRIPLE="$2"; shift 2 ;;
	--profile) PROFILE="$2"; shift 2 ;;
	--features) FEATURES="$2"; shift 2 ;;
	--no-jemalloc) NO_JEMALLOC=1; shift ;;
	--engine) ENGINE="$2"; shift 2 ;;
	--ca-cert) CA_CERT="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	--jobs) JOBS="$2"; shift 2 ;;
	--rebuild-image) REBUILD_IMAGE=1; shift ;;
	--clean) CLEAN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "build-static-opreth: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

cd "$(git rev-parse --show-toplevel)"
ROOT="$PWD"

case "$TRIPLE" in
x86_64-unknown-linux-musl) MUSL_PREFIX="x86_64-linux-musl" ;;
aarch64-unknown-linux-musl) MUSL_PREFIX="aarch64-linux-musl" ;;
*)
	echo "build-static-opreth: unsupported --target $TRIPLE" >&2
	echo "                     (x86_64-unknown-linux-musl or aarch64-unknown-linux-musl)" >&2
	exit 2
	;;
esac

# cargo puts the `dev` profile in target/debug; every other profile uses its name.
PROFILE_DIR="$PROFILE"
if [ "$PROFILE" = "dev" ]; then PROFILE_DIR="debug"; fi

if [ -z "$ENGINE" ]; then
	for candidate in docker podman; do
		if command -v "$candidate" >/dev/null 2>&1; then ENGINE="$candidate"; break; fi
	done
fi
if [ -z "$ENGINE" ] || ! command -v "$ENGINE" >/dev/null 2>&1; then
	echo "build-static-opreth: need docker or podman on PATH (on Rocky: dnf install -y podman)" >&2
	exit 1
fi

VOL_TARGET="opreth-musl-target-$TRIPLE"
VOL_CARGO="opreth-musl-cargo"

if [ "$CLEAN" = 1 ]; then
	"$ENGINE" volume rm -f "$VOL_TARGET" "$VOL_CARGO" || true
	exit 0
fi

if [ -n "$CA_CERT" ] && [ ! -s "$CA_CERT" ]; then
	echo "build-static-opreth: --ca-cert $CA_CERT is missing or empty" >&2
	exit 1
fi

# cross-rs publishes these images for amd64 only, so anywhere else every rustc
# and cc invocation runs under QEMU.
case "$(uname -m)" in
x86_64 | amd64) ;;
*)
	echo "build-static-opreth: WARNING: the builder image is amd64-only and this host is" >&2
	echo "                     $(uname -m), so the build runs under emulation and will take" >&2
	echo "                     hours. Run this on the x86_64 target box instead." >&2
	;;
esac

# reth-optimism-chainspec's build.rs needs one of the two: the prebuilt archive,
# or the submodule to regenerate it from. Fail now rather than 40 minutes in.
if [ ! -f rust/op-reth/crates/chainspec/res/superchain-configs.tar ] &&
	[ ! -f superchain-registry/chainList.json ]; then
	echo "build-static-opreth: neither rust/op-reth/crates/chainspec/res/superchain-configs.tar" >&2
	echo "                     nor the superchain-registry submodule is present." >&2
	echo "                     Run: just update-superchain-registry-submodule" >&2
	exit 1
fi

CHANNEL="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' rust/rust-toolchain.toml | head -1)"
if [ -z "$CHANNEL" ]; then
	echo "build-static-opreth: could not read the toolchain channel from rust/rust-toolchain.toml" >&2
	exit 1
fi

IMAGE="opreth-musl-builder:$CHANNEL-$TRIPLE"
[ -n "$OUT" ] || OUT="$ROOT/ralim/dist/op-reth-$TRIPLE"
mkdir -p "$(dirname "$OUT")"
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"   # absolute: the engine needs it for -v
OUT_NAME="$(basename "$OUT")"

echo "==> engine=$ENGINE target=$TRIPLE toolchain=$CHANNEL profile=$PROFILE"

# ---------------------------------------------------------------------------
# Builder image: cross-rs's musl toolchain image + the workspace's pinned Rust.
# Built from a scratch context so nothing of the repo is uploaded to the daemon.
# ---------------------------------------------------------------------------
if [ "$REBUILD_IMAGE" = 1 ] || ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
	CTX="$(mktemp -d)"
	trap 'rm -rf "$CTX"' EXIT
	if [ -n "$CA_CERT" ]; then cp "$CA_CERT" "$CTX/ca.pem"; else : >"$CTX/ca.pem"; fi
	cat >"$CTX/Dockerfile" <<'DOCKERFILE'
ARG CHANNEL=1
ARG TRIPLE=x86_64-unknown-linux-musl

# The pinned toolchain, with the musl target's std, from the official image —
# cheaper and more predictable than running rustup.sh in the builder.
FROM rust:${CHANNEL}-bookworm AS toolchain
ARG TRIPLE
COPY ca.pem /tmp/ca.pem
RUN if [ -s /tmp/ca.pem ]; then cat /tmp/ca.pem >> /etc/ssl/certs/ca-certificates.crt; fi
RUN rustup target add "$TRIPLE" && rustup component add rustfmt

# cross-rs's image carries the musl-cross toolchain (gcc *and* g++, with a
# musl-built libstdc++.a that librocksdb-sys needs) on an Ubuntu userland, so
# build scripts are dynamically linked and bindgen can dlopen libclang.
FROM ghcr.io/cross-rs/${TRIPLE}:main
COPY ca.pem /tmp/ca.pem
RUN if [ -s /tmp/ca.pem ]; then cat /tmp/ca.pem >> /etc/ssl/certs/ca-certificates.crt; fi
COPY --from=toolchain /usr/local/rustup /usr/local/rustup
COPY --from=toolchain /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/cargo/bin:$PATH
RUN git --version && cargo --version && ls /usr/local/bin/*-linux-musl-g++
DOCKERFILE
	echo "==> building $IMAGE"
	"$ENGINE" build --platform linux/amd64 \
		--build-arg "CHANNEL=$CHANNEL" --build-arg "TRIPLE=$TRIPLE" \
		-t "$IMAGE" "$CTX"
	rm -rf "$CTX"
	trap - EXIT
fi

# ---------------------------------------------------------------------------
# The build itself.
# ---------------------------------------------------------------------------
FEATURE_ARGS=()
if [ "$NO_JEMALLOC" = 1 ]; then
	# cargo cannot subtract a default feature, so restate the defaults minus jemalloc.
	FEATURE_ARGS+=(--no-default-features --features
		"otlp,js-tracer,keccak-cache-global,asm-keccak,reth-optimism-evm/portable${FEATURES:+,$FEATURES}")
elif [ -n "$FEATURES" ]; then
	FEATURE_ARGS+=(--features "$FEATURES")
fi

# cargo's linker override wants the triple SHOUTED; the cc crate and bindgen want
# it lowercased with underscores.
TRIPLE_ENV="$(printf '%s' "$TRIPLE" | tr 'a-z-' 'A-Z_')"
TRIPLE_US="$(printf '%s' "$TRIPLE" | tr '-' '_')"
SYSROOT="/usr/local/$MUSL_PREFIX"

# Build state lives in engine-managed volumes, not on the bind mount. Three
# reasons, in order of how badly each bites:
#   - rootless podman (the Rocky default) remaps uids, so a container writing to
#     a bind-mounted target/ hits EPERM unless --userns=keep-id lines up exactly;
#   - a bind mount over virtiofs/9p (Docker Desktop) is not coherent enough for a
#     build this parallel — rustc has been seen to miss an rlib another rustc had
#     just written, surfacing as a bogus "can't find crate for alloy_primitives";
#   - nothing under the repo ends up root-owned.
# The repo itself is still mounted, because build.rs scripts read it (and
# reth-optimism-chainspec's may regenerate its superchain archive in place).
RUN_ARGS=(
	--rm --init
	--platform linux/amd64
	# Rocky enforces SELinux; without this a bind mount is denied rather than
	# relabelled. A no-op where SELinux is not in play.
	--security-opt label=disable
	-v "$ROOT:/src"
	-v "$VOL_TARGET:/build/target"
	-v "$VOL_CARGO:/build/cargo-home"
	-v "$OUT_DIR:/out"
	-e CARGO_HOME=/build/cargo-home
	-e CARGO_TARGET_DIR=/build/target
	-e CARGO_NET_RETRY=5
	-e CARGO_TERM_COLOR=always
	# Point every stage of the target build at the musl-cross toolchain: rustc's
	# final link, the cc crate's C and C++ compiles, and bindgen's header parse.
	-e "CARGO_TARGET_${TRIPLE_ENV}_LINKER=$MUSL_PREFIX-gcc"
	-e "CC_${TRIPLE_US}=$MUSL_PREFIX-gcc"
	-e "CXX_${TRIPLE_US}=$MUSL_PREFIX-g++"
	-e "AR_${TRIPLE_US}=$MUSL_PREFIX-ar"
	-e "RANLIB_${TRIPLE_US}=$MUSL_PREFIX-ranlib"
	-e "BINDGEN_EXTRA_CLANG_ARGS_${TRIPLE_US}=--sysroot=$SYSROOT"
	-e "BINDGEN_EXTRA_CLANG_ARGS_${TRIPLE}=--sysroot=$SYSROOT"
	-e "HOST_UID=$(id -u)"
	-e "HOST_GID=$(id -g)"
	-e "OUT_NAME=$OUT_NAME"
)
if [ -n "$JOBS" ]; then RUN_ARGS+=(-e "CARGO_BUILD_JOBS=$JOBS"); fi
# jemalloc bakes in the page size; aarch64 kernels may use 64K pages and a
# 4K-assuming build then aborts at startup. Mirrors op-reth's own Cross.toml.
if [ "$TRIPLE" = "aarch64-unknown-linux-musl" ]; then
	RUN_ARGS+=(-e JEMALLOC_SYS_WITH_LG_PAGE=16)
fi

# Killing the client does not kill the container, and an orphan holds cargo's
# package-cache lock — the next run then hangs on "Blocking waiting for file
# lock" forever. Name it and tear it down on any exit.
CONTAINER="opreth-musl-build-$$"
cleanup_container() { "$ENGINE" rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup_container EXIT INT TERM

"$ENGINE" run --name "$CONTAINER" "${RUN_ARGS[@]}" \
	-w /src/rust "$IMAGE" bash -euc '
		TRIPLE="$1"; PROFILE="$2"; PROFILE_DIR="$3"; shift 3
		git config --global --add safe.directory /src

		# rust-toolchain.toml pins the channel as e.g. "1.94", which rustup treats
		# as a name to resolve over the network even though the image already ships
		# that exact toolchain — left alone it re-downloads the channel on every
		# run. RUSTUP_TOOLCHAIN outranks rust-toolchain.toml, so pin it to what is
		# installed. Read the name off disk rather than from `rustup toolchain
		# list`, because invoking any rustup proxy is itself the trigger.
		RUSTUP_TOOLCHAIN="$(ls "${RUSTUP_HOME:-/usr/local/rustup}/toolchains" | head -1)"
		export RUSTUP_TOOLCHAIN
		[ -n "$RUSTUP_TOOLCHAIN" ] || { echo "no toolchain in the builder image" >&2; exit 1; }
		echo "==> toolchain $RUSTUP_TOOLCHAIN, host $(rustc -vV | sed -n "s/^host: //p")"

		cargo build --locked --bin op-reth \
			--manifest-path /src/rust/op-reth/bin/Cargo.toml \
			--target "$TRIPLE" --profile "$PROFILE" "$@"

		BIN="/build/target/$TRIPLE/$PROFILE_DIR/op-reth"
		echo "==> verifying the binary is actually static"
		file "$BIN"
		if readelf -l "$BIN" | grep -q INTERP; then
			echo "FAIL: $BIN has a PT_INTERP segment, so it is dynamically linked" >&2
			readelf -d "$BIN" >&2
			exit 1
		fi
		echo "OK: no PT_INTERP — no runtime loader, no libc to match on the host"

		install -m 0755 "$BIN" "/out/$OUT_NAME"
		# Under rootful docker the container is root and everything it wrote to the
		# bind mounts would land root-owned; hand it back. Under rootless podman
		# these are already the invoking user and the chown is a harmless no-op.
		chown "$HOST_UID:$HOST_GID" "/out/$OUT_NAME" 2>/dev/null || true
		chown -R "$HOST_UID:$HOST_GID" /src/rust/op-reth/crates/chainspec/res 2>/dev/null || true
	' _ "$TRIPLE" "$PROFILE" "$PROFILE_DIR" ${FEATURE_ARGS[@]+"${FEATURE_ARGS[@]}"}

echo
echo "==> $OUT_DIR/$OUT_NAME"
ls -l "$OUT_DIR/$OUT_NAME"
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum "$OUT_DIR/$OUT_NAME"
elif command -v shasum >/dev/null 2>&1; then
	shasum -a 256 "$OUT_DIR/$OUT_NAME"
fi
echo
echo "On the Rocky host: \`ldd $OUT_NAME\` should say \"not a dynamic executable\"."
if [ "$PROFILE" = "release" ]; then
	echo "For the profile upstream ships its images with, rerun with --profile maxperf."
fi
exit 0
