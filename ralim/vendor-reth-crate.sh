#!/usr/bin/env bash
# Re-vendor one of this fork's copies of a reth crate from the reth revision the
# base tag pins, then re-apply the fork's changes from ralim/patches/<crate>.patch.
#
#   ./ralim/vendor-reth-crate.sh <crate>               # re-vendor + apply the patch
#   ./ralim/vendor-reth-crate.sh <crate> --save-patch  # regenerate the patch from the tree
#   ./ralim/vendor-reth-crate.sh --list                # the crates this fork vendors
#
# Run the first form for every vendored crate after a base-tag change that moves
# the reth pin: each vendored copy must match the reth version the rest of the
# workspace builds against, or the patched crate and its dependents disagree on
# types.
#
# The pin (git URL plus tag or rev) is read from rust/Cargo.toml, so this script
# follows the pin automatically instead of hardcoding a version.
#
# See ralim/README.md.
set -euo pipefail

# crate -> its source directory inside the reth repo. Adding a vendored crate
# means an entry here plus, in rust/Cargo.toml, a `members` entry, a `[patch]`
# entry, and any `[workspace.dependencies]` keys the crate's manifest expects.
# ./ralim/check-patches.sh asserts the patch is live.
crate_subdir() {
	case "$1" in
	reth-downloaders) echo crates/net/downloaders ;;
	reth-tasks) echo crates/tasks ;;
	*) return 1 ;;
	esac
}
CRATES="reth-downloaders reth-tasks"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

CRATE=""
SAVE_PATCH=0
while [ $# -gt 0 ]; do
	case "$1" in
	--save-patch) SAVE_PATCH=1; shift ;;
	--list) printf '%s\n' $CRATES; exit 0 ;;
	-h|--help) usage; exit 0 ;;
	-*) die "unknown option: $1" ;;
	*) [ -z "$CRATE" ] || die "only one crate at a time (got $CRATE and $1)"; CRATE="$1"; shift ;;
	esac
done

[ -n "$CRATE" ] || { usage >&2; die "which crate? one of: $CRATES"; }
SRC_SUBDIR="$(crate_subdir "$CRATE")" || die "$CRATE is not vendored by this fork (see --list)"
DEST="rust/ralim/vendor/$CRATE"
PATCH="ralim/patches/$CRATE.patch"

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
	# diff's mtimes and absolute paths so regenerating an unchanged patch is a
	# no-op in git. The tab has to be a literal one: BSD sed (macOS) reads "\t"
	# in a pattern as the letter t, so the mtimes used to survive here.
	TAB="$(printf '\t')"
	sed -e "s|^--- pristine/|--- a/|" -e "s|^+++ .*$DEST/|+++ b/|" \
		-e "s|^--- pristine$|--- a|" -e "s|^+++ .*$DEST$|+++ b|" \
		-e "s|^\(--- [^$TAB]*\)$TAB.*$|\1|" -e "s|^\(+++ [^$TAB]*\)$TAB.*$|\1|" \
		-e "s|^diff \(.*\)pristine/\([^ ]*\) .*$|diff \1a/\2 b/\2|" \
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
	        ./ralim/vendor-reth-crate.sh $CRATE --save-patch

	    Every one of these patches is small by design; see ralim/README.md for
	    what each vendored crate changes and why.
	MSG
	exit 1
fi

step "Next"
info "cargo check -p $CRATE   # the vendored copy still builds"
info "./ralim/check-patches.sh       # the [patch] is actually active"
info "cargo check -p reth-optimism-node   # dependents still typecheck"
