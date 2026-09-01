#!/usr/bin/env bash
# Re-vendor rust/ralim/vendor/reth-downloaders from the reth revision the base
# tag pins, then re-apply this fork's changes from
# ralim/patches/reth-downloaders.patch.
#
#   ./ralim/vendor-reth-downloaders.sh              # re-vendor + apply the patch
#   ./ralim/vendor-reth-downloaders.sh --save-patch # regenerate the patch from the vendored tree
#
# Run the first form after every base-tag change that moves the reth pin: the
# vendored copy must match the reth version the rest of the workspace builds
# against, or the patched crate and its dependencies disagree on types.
#
# The pin (git URL plus tag or rev) is read from rust/Cargo.toml, so this script
# follows the pin automatically instead of hardcoding a version.
#
# See ralim/README.md.
set -euo pipefail

CRATE=reth-downloaders
SRC_SUBDIR=crates/net/downloaders
DEST=rust/ralim/vendor/reth-downloaders
PATCH=ralim/patches/reth-downloaders.patch

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

SAVE_PATCH=0
case "${1-}" in
	"") ;;
	--save-patch) SAVE_PATCH=1 ;;
	-h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1" ;;
esac

cd "$(git rev-parse --show-toplevel)" || die "not inside a git repository"

# ---------------------------------------------------------------- read the pin

read -r PIN_URL PIN_KIND PIN_REF <<EOF
$(CRATE="$CRATE" python3 - <<'PY'
import os, re, sys, pathlib

crate = os.environ["CRATE"]
text = pathlib.Path("rust/Cargo.toml").read_text()

# The [workspace.dependencies] entry, not the [patch] one: the patch points at
# the vendored copy, the dependency records where upstream lives.
deps = text.split("[workspace.dependencies]", 1)
if len(deps) < 2:
    sys.exit(f"no [workspace.dependencies] in rust/Cargo.toml")
section = deps[1].split("\n[patch", 1)[0]

m = re.search(rf'(?m)^{re.escape(crate)}\s*=\s*\{{([^}}]*)\}}', section)
if not m:
    sys.exit(f"no {crate} entry in [workspace.dependencies]")
spec = m.group(1)

url = re.search(r'git\s*=\s*"([^"]+)"', spec)
if not url:
    sys.exit(f"{crate} is not a git dependency; nothing to vendor from")
tag = re.search(r'tag\s*=\s*"([^"]+)"', spec)
rev = re.search(r'rev\s*=\s*"([^"]+)"', spec)
if tag:
    print(url.group(1), "tag", tag.group(1))
elif rev:
    print(url.group(1), "rev", rev.group(1))
else:
    sys.exit(f"{crate} pins neither a tag nor a rev")
PY
)
EOF

[ -n "${PIN_URL:-}" ] || die "could not read the reth pin from rust/Cargo.toml"

step "Pin"
info "$CRATE <- $PIN_URL ($PIN_KIND $PIN_REF)"

# ------------------------------------------------------------ fetch pristine

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PRISTINE="$TMP/pristine"

step "Fetching the pristine crate"
if [ "$PIN_KIND" = tag ]; then
	git clone --quiet --depth 1 --branch "$PIN_REF" --filter=blob:none --sparse \
		"$PIN_URL" "$TMP/reth" || die "clone failed"
else
	git init --quiet "$TMP/reth"
	git -C "$TMP/reth" remote add origin "$PIN_URL"
	git -C "$TMP/reth" fetch --quiet --depth 1 --filter=blob:none origin "$PIN_REF" \
		|| die "could not fetch rev $PIN_REF from $PIN_URL"
	git -C "$TMP/reth" sparse-checkout init --cone >/dev/null 2>&1 || true
	git -C "$TMP/reth" checkout --quiet FETCH_HEAD
fi
git -C "$TMP/reth" sparse-checkout set "$SRC_SUBDIR" >/dev/null
[ -d "$TMP/reth/$SRC_SUBDIR" ] || die "$SRC_SUBDIR not found at $PIN_KIND $PIN_REF"
cp -R "$TMP/reth/$SRC_SUBDIR" "$PRISTINE"
info "$(find "$PRISTINE" -type f | wc -l | tr -d ' ') files"

# --------------------------------------------------------------------- modes

if [ "$SAVE_PATCH" -eq 1 ]; then
	step "Regenerating $PATCH"
	[ -d "$DEST" ] || die "$DEST does not exist; nothing to diff"
	mkdir -p "$(dirname "$PATCH")"
	# diff exits 1 when there are differences, which is the expected case here.
	(cd "$TMP" && diff -ruN --exclude=target pristine "$OLDPWD/$DEST" > "$OLDPWD/$PATCH.tmp") || true
	# Normalise the paths so the patch applies with -p1 inside $DEST, and strip
	# diff's mtimes so regenerating an unchanged patch is a no-op in git.
	sed -e "s|^--- pristine/|--- a/|" -e "s|^+++ .*$DEST/|+++ b/|" \
		-e "s|^--- pristine$|--- a|" -e "s|^+++ .*$DEST$|+++ b|" \
		-e "s|^\(--- [^\t]*\)\t.*$|\1|" -e "s|^\(+++ [^\t]*\)\t.*$|\1|" \
		"$PATCH.tmp" > "$PATCH"
	rm -f "$PATCH.tmp"
	info "$(grep -c '^--- ' "$PATCH" || true) file(s), $(wc -l < "$PATCH" | tr -d ' ') lines"
	info "review it, then commit both the patch and the vendored tree"
	exit 0
fi

[ -f "$PATCH" ] || die "$PATCH not found — generate it first with --save-patch"

step "Re-vendoring $DEST"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$PRISTINE" "$DEST"
info "pristine copy in place"

step "Applying $PATCH"
if ! patch -p1 -d "$DEST" --forward < "$PATCH"; then
	cat >&2 <<-MSG

	The fork's changes did not apply cleanly to the new reth revision.

	    Resolve the .rej files under $DEST by hand, then record the result:
	        ./ralim/vendor-reth-downloaders.sh --save-patch

	    The change is small by design — the two downloader builders wrap their
	    client in ralim-p2p-ratelimit's RateLimitedClient, plus the manifest
	    edits. See ralim/README.md.
	MSG
	exit 1
fi

step "Next"
info "cargo check -p $CRATE          # the vendored copy still builds"
info "./ralim/check-patches.sh       # the [patch] is actually active"
info "cargo check -p reth-optimism-node   # dependents still typecheck"
