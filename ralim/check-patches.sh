#!/usr/bin/env bash
# Assert that this fork's `[patch]` entries are actually active in the cargo
# crate graph.
#
# This exists because of how cargo fails here: if a `[patch]` key stops matching
# the pinned dependency's source URL — which is exactly what a reth bump or a
# base-tag change does — cargo does not error. It prints "Patch ... was not used
# in the crate graph" and builds happily against the unpatched upstream crate.
# The rate limiter would silently disappear. So we check, and the pre-push hook
# runs this.
#
# Usage: ./ralim/check-patches.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# package name -> path its manifest must live under, relative to the repo root
PATCHED_CRATES="reth-downloaders:rust/ralim/vendor/reth-downloaders reth-tasks:rust/ralim/vendor/reth-tasks reth-db:rust/ralim/vendor/reth-db"

cargo_cmd() {
	if command -v cargo >/dev/null 2>&1; then
		cargo "$@"
	elif command -v mise >/dev/null 2>&1; then
		mise exec -- cargo "$@"
	else
		return 127
	fi
}

if ! command -v cargo >/dev/null 2>&1 && ! command -v mise >/dev/null 2>&1; then
	echo "check-patches: cargo unavailable; skipping (install the mise toolchain to run this)" >&2
	exit 0
fi

echo "==> resolving the cargo graph for rust/"
# Run from inside rust/ so rust/rust-toolchain.toml selects the pinned toolchain;
# from the repo root cargo would be whatever rustup defaults to, which can be too
# old to parse the workspace.
if ! meta="$(cd rust && cargo_cmd metadata --format-version 1 2>/tmp/ralim-patch-check.err)"; then
	sed 's/^/    /' /tmp/ralim-patch-check.err >&2
	echo "check-patches: cargo metadata failed" >&2
	exit 1
fi

# cargo reports an inert patch as a warning, not an error.
if grep -q "was not used in the crate graph" /tmp/ralim-patch-check.err; then
	grep "was not used in the crate graph" /tmp/ralim-patch-check.err | sed 's/^/    /' >&2
	cat >&2 <<-MSG

	check-patches: a [patch] entry in rust/Cargo.toml is inert.

	    The patch key must match the pinned dependency's source URL exactly.
	    Compare the [patch."<url>"] header against the reth-* entries in
	    [workspace.dependencies] — a base-tag change can move that URL (for
	    example paradigmxyz/reth -> op-rs/reth).
	MSG
	exit 1
fi

# Reads the metadata JSON on stdin, prints where $PKG resolved.
RESOLVE_PY='
import json, os, sys
meta = json.load(sys.stdin)
name = os.environ["PKG"]
hits = [p for p in meta["packages"] if p["name"] == name]
if not hits:
    print("MISSING")
elif len(hits) > 1:
    print("DUPLICATE " + " ".join(sorted(p["manifest_path"] for p in hits)))
else:
    print(hits[0]["manifest_path"])
'

status=0
for entry in $PATCHED_CRATES; do
	name="${entry%%:*}"
	want="${entry#*:}"

	resolved="$(printf '%s' "$meta" | PKG="$name" python3 -c "$RESOLVE_PY")"

	case "$resolved" in
		MISSING)
			echo "    ✗ $name is not in the crate graph at all" >&2
			status=1
			;;
		DUPLICATE*)
			echo "    ✗ $name resolves to more than one source:" >&2
			printf '        %s\n' ${resolved#DUPLICATE } >&2
			echo "      Both the patched copy and the upstream crate are being built." >&2
			status=1
			;;
		"$PWD/$want/Cargo.toml")
			echo "    ✓ $name -> $want"
			;;
		*)
			echo "    ✗ $name resolves to $resolved" >&2
			echo "      expected the vendored copy at $want" >&2
			status=1
			;;
	esac
done

rm -f /tmp/ralim-patch-check.err

if [ "$status" -ne 0 ]; then
	echo >&2
	echo "check-patches: the fork's P2P download rate limiter is NOT wired in." >&2
	echo "See ralim/README.md." >&2
	exit 1
fi

echo "all [patch] entries active"
