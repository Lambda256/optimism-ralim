#!/usr/bin/env bash
#
# Rebase this fork's patch branch onto a new upstream OP Stack release tag.
#
#   ./ralim/rebase-new-tag.sh v2.4.2                  # short form: op-reth/v2.4.2
#   ./ralim/rebase-new-tag.sh op-reth/v2.4.2 --push
#   ./ralim/rebase-new-tag.sh v2.4.2 --from op-reth/v2.3.3 --no-verify
#   ./ralim/rebase-new-tag.sh v2.4.2 --verify-build    # also cargo/go build
#
# Tags in this monorepo are component-scoped (op-reth/vX.Y.Z, op-node/vX.Y.Z);
# a bare vX.Y.Z is prefixed with $TAG_PREFIX.
#
# The current base tag is derived from the repository, not stored anywhere: the
# patch branch forks off upstream history at exactly its base commit, so
# `git merge-base <patch branch> upstream/develop` recovers it. --from overrides
# that when the derivation cannot work (e.g. a tag off a maintenance branch).
#
# Nothing is pushed unless --push is given. A backup ref is always written
# first, so the whole run can be undone with a single git update-ref.

set -euo pipefail

PATCH_BRANCH=ralim
MIRROR_BRANCH=develop
TAG_PREFIX=op-reth/
UPSTREAM=upstream
ORIGIN=origin

usage() {
	sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

NEW_TAG=""
FROM_TAG=""
DO_PUSH=0
DO_MIRROR=1
DO_VERIFY=1
DO_BUILD=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help)      usage 0 ;;
		--from)         FROM_TAG="${2:-}"; [ -n "$FROM_TAG" ] || die "--from needs a tag"; shift 2 ;;
		--push)         DO_PUSH=1; shift ;;
		--no-mirror)    DO_MIRROR=0; shift ;;
		--no-verify)    DO_VERIFY=0; shift ;;
		--verify-build) DO_BUILD=1; shift ;;
		-y|--yes)       ASSUME_YES=1; shift ;;
		-*)             die "unknown option: $1" ;;
		*)              [ -z "$NEW_TAG" ] || die "unexpected argument: $1"; NEW_TAG="$1"; shift ;;
	esac
done

[ -n "$NEW_TAG" ] || usage 1

# Bare version -> component-scoped tag (a sha or an already-scoped tag is left alone).
case "$NEW_TAG" in v[0-9]*) NEW_TAG="${TAG_PREFIX}${NEW_TAG}" ;; esac
case "${FROM_TAG:-}" in v[0-9]*) FROM_TAG="${TAG_PREFIX}${FROM_TAG}" ;; esac

# ---------------------------------------------------------------- preconditions

cd "$(git rev-parse --show-toplevel)" || die "not inside a git repository"

git remote get-url "$UPSTREAM" >/dev/null 2>&1 \
	|| die "no '$UPSTREAM' remote. Run: git remote add $UPSTREAM https://github.com/ethereum-optimism/optimism.git"

if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
	die "a rebase is already in progress. Finish it with 'git rebase --continue' or 'git rebase --abort' first."
fi

if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
	git status --short >&2
	die "working tree is not clean. Commit or stash first - a rebase needs a clean tree."
fi

git rev-parse --verify --quiet "refs/heads/$PATCH_BRANCH" >/dev/null \
	|| die "no local '$PATCH_BRANCH' branch"

START_BRANCH="$(git symbolic-ref --short -q HEAD || echo '')"

# ------------------------------------------------------------------------ fetch

step "Fetching $UPSTREAM (tags included)"
# Output is captured, not streamed: the monorepo's .gitmodules trips a harmless
# multi-config warning on old refs. It is shown only if the fetch actually fails.
fetch_out="$(git fetch --quiet "$UPSTREAM" --tags --prune 2>&1)" || die "fetch failed:
$(printf '%s\n' "$fetch_out" | sed 's/^/      /')"
info "done"

NEW_SHA="$(git rev-parse --verify --quiet "${NEW_TAG}^{commit}" || true)"
[ -n "$NEW_SHA" ] || die "tag '$NEW_TAG' does not exist upstream. Available:
$(git tag -l "${TAG_PREFIX}v*" --sort=-v:refname | head -8 | sed 's/^/      /')"

# ------------------------------------------------------- resolve the old base

if [ -n "$FROM_TAG" ]; then
	OLD_SHA="$(git rev-parse --verify --quiet "${FROM_TAG}^{commit}" || true)"
	[ -n "$OLD_SHA" ] || die "--from tag '$FROM_TAG' does not exist"
else
	OLD_SHA="$(git merge-base "$PATCH_BRANCH" "$UPSTREAM/$MIRROR_BRANCH")" \
		|| die "cannot derive the current base; pass it explicitly with --from <tag>"
	FROM_TAG="$(git describe --tags --exact-match "$OLD_SHA" 2>/dev/null || echo "$(git rev-parse --short "$OLD_SHA") (untagged)")"
fi

[ "$OLD_SHA" != "$NEW_SHA" ] || die "$PATCH_BRANCH is already based on $NEW_TAG - nothing to do"

if ! git merge-base --is-ancestor "$OLD_SHA" "$NEW_SHA"; then
	warn "$NEW_TAG is not a descendant of the current base $FROM_TAG."
	warn "This moves the patch stack sideways or backwards, not forward."
	if [ "$ASSUME_YES" -eq 1 ]; then
		info "--yes given; continuing"
	else
		printf '    Continue anyway? [y/N] '
		read -r reply </dev/tty || reply=n
		case "$reply" in [yY]*) ;; *) die "aborted" ;; esac
	fi
fi

PATCH_COUNT="$(git rev-list --count "$OLD_SHA..$PATCH_BRANCH")"

step "Plan"
info "patch branch : $PATCH_BRANCH ($PATCH_COUNT commit(s) to replay)"
info "current base : $FROM_TAG  ($(git rev-parse --short "$OLD_SHA"))"
info "new base     : $NEW_TAG  ($(git rev-parse --short "$NEW_SHA"))"
git log --oneline "$OLD_SHA..$PATCH_BRANCH" | sed 's/^/      /'

# ----------------------------------------------------------------- backup ref

BACKUP="refs/fork-backup/${PATCH_BRANCH}-$(date +%Y%m%d-%H%M%S)"
git update-ref "$BACKUP" "$(git rev-parse "$PATCH_BRANCH")"
ROLLBACK="git update-ref refs/heads/$PATCH_BRANCH $BACKUP && git checkout -f $PATCH_BRANCH"

step "Backup"
info "$BACKUP -> $(git rev-parse --short "$PATCH_BRANCH")"
info "roll back with: $ROLLBACK"

# ------------------------------------------------------------- mirror the tip

if [ "$DO_MIRROR" -eq 1 ]; then
	step "Fast-forwarding the $MIRROR_BRANCH mirror"
	git checkout --quiet "$PATCH_BRANCH"   # fetching into the current branch is refused
	if git rev-parse --verify --quiet "refs/heads/$MIRROR_BRANCH" >/dev/null; then
		if git fetch --quiet . "$UPSTREAM/$MIRROR_BRANCH:$MIRROR_BRANCH" 2>/dev/null; then
			info "$MIRROR_BRANCH -> $(git rev-parse --short "$MIRROR_BRANCH")"
		else
			warn "could not fast-forward $MIRROR_BRANCH (it has diverged from $UPSTREAM/$MIRROR_BRANCH); skipping"
		fi
	else
		warn "no local '$MIRROR_BRANCH' branch; skipping"
	fi
fi

# ---------------------------------------------------------------------- rebase

step "Rebasing $PATCH_BRANCH onto $NEW_TAG"

rebase_in_progress() {
	[ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]
}

# rust/Cargo.lock is generated. Hand-merging it produces a lockfile that matches
# neither side's manifests, so take the new base's copy and re-lock instead.
LOCKFILE=rust/Cargo.lock

# The repo's tools come from mise; fall back to it when they are not on PATH.
# Exit code 127 means "tool unavailable" and is treated as a skip, not a failure.
cargo_cmd() {
	if command -v cargo >/dev/null 2>&1; then
		cargo "$@"
	elif command -v mise >/dev/null 2>&1; then
		mise exec -- cargo "$@"
	else
		return 127
	fi
}

just_cmd() {
	if command -v just >/dev/null 2>&1; then
		just "$@"
	elif command -v mise >/dev/null 2>&1; then
		mise exec -- just "$@"
	else
		return 127
	fi
}

resolve_lockfile() {
	local unmerged
	unmerged="$(git diff --name-only --diff-filter=U)"
	[ "$unmerged" = "$LOCKFILE" ] || return 1

	info "only $LOCKFILE conflicts - re-locking instead of merging by hand"
	# During a rebase --ours is the new base, --theirs the commit being replayed.
	git checkout --ours -- "$LOCKFILE"
	if ! cargo_cmd metadata --manifest-path rust/Cargo.toml --format-version 1 >/dev/null 2>&1; then
		warn "could not re-lock (cargo unavailable, or the patch adds a dependency that needs the network)"
		return 1
	fi
	git add "$LOCKFILE"
	return 0
}

set +e
git rebase --onto "$NEW_SHA" "$OLD_SHA" "$PATCH_BRANCH"
rebase_status=$?
set -e

while [ "$rebase_status" -ne 0 ] && rebase_in_progress; do
	resolve_lockfile || break
	set +e
	GIT_EDITOR=true git rebase --continue
	rebase_status=$?
	set -e
done

if [ "$rebase_status" -ne 0 ]; then
	printf '\n'
	warn "the rebase stopped with conflicts. It is left in progress on purpose."
	printf '    Conflicting files:\n'
	git diff --name-only --diff-filter=U | sed 's/^/      /'
	cat <<-MSG

	    Resolve them, then:   git add <files> && git rebase --continue
	    Give up entirely:     git rebase --abort
	    Undo everything:      $ROLLBACK

	    Reminder: never hand-merge $LOCKFILE. Take either side, then run
	    'cargo metadata --manifest-path rust/Cargo.toml' to rebuild it.

	    A conflict in an upstream-owned file means the patch stack reaches
	    outside ralim/. Consider moving that change into a fork-owned file so
	    the next tag bump replays cleanly - see ralim/README.md.
	MSG
	exit 1
fi

info "replayed $PATCH_COUNT commit(s) cleanly"

# ---------------------------------------------------------------------- verify

if [ "$DO_VERIFY" -eq 1 ]; then
	step "Verifying"

	touched="$(git diff --name-only "$NEW_SHA..$PATCH_BRANCH")"
	rust_touched=$(printf '%s\n' "$touched" | grep -c '\.rs$' || true)
	go_touched=$(printf '%s\n' "$touched" | grep -c '\.go$' || true)

	if [ "$rust_touched" -gt 0 ]; then
		# The repo's own gate, pinned nightly and all: the same target its
		# .githooks/pre-push runs. Plain `cargo fmt` would use the stable
		# toolchain and can disagree with rust/rustfmt.toml.
		set +e
		(cd rust && just_cmd fmt-check-all >/dev/null 2>&1)
		st=$?
		set -e
		case "$st" in
			0)   info "rust fmt     ok" ;;
			127) warn "just/mise unavailable; skipped the Rust fmt check" ;;
			*)   die "Rust formatting check failed - run 'just fmt-fix' in rust/, amend the patch, then re-run" ;;
		esac
	fi

	if [ "$go_touched" -gt 0 ]; then
		go_dirs="$(printf '%s\n' "$touched" | grep '\.go$' | xargs -n1 dirname 2>/dev/null | sort -u)"
		if command -v gofmt >/dev/null 2>&1; then
			fmt_out="$(gofmt -l $go_dirs 2>/dev/null || true)"
			[ -z "$fmt_out" ] || { printf '%s\n' "$fmt_out" | sed 's/^/      /'; die "gofmt reports unformatted files"; }
			info "gofmt        ok"
		else
			warn "gofmt unavailable; skipped the Go fmt check"
		fi
	fi

	if [ "$rust_touched" -eq 0 ] && [ "$go_touched" -eq 0 ]; then
		info "no Rust or Go changes in the patch stack; nothing to check"
	fi

	# Builds are opt-in: a cold cargo check of this workspace takes many minutes.
	if [ "$DO_BUILD" -eq 1 ]; then
		if [ "$rust_touched" -gt 0 ]; then
			step "Building (Rust)"
			(cd rust && cargo_cmd check --workspace) || die "cargo check failed on $NEW_TAG. Fix the patch, then re-run."
			info "cargo check  ok"
		fi
		if [ "$go_touched" -gt 0 ]; then
			step "Building (Go)"
			go build ./... || die "go build failed on $NEW_TAG. Fix the patch, then re-run."
			info "go build     ok"
		fi
	else
		info "builds skipped (pass --verify-build to run cargo check / go build)"
	fi
fi

# ------------------------------------------------------------------------ push

step "Result"
info "$PATCH_BRANCH is now $NEW_TAG + $PATCH_COUNT commit(s)  ($(git rev-parse --short "$PATCH_BRANCH"))"

if [ "$DO_PUSH" -eq 1 ]; then
	step "Pushing"
	if [ "$DO_MIRROR" -eq 1 ] && git rev-parse --verify --quiet "refs/heads/$MIRROR_BRANCH" >/dev/null; then
		git push "$ORIGIN" "$MIRROR_BRANCH"
	fi
	git push --force-with-lease "$ORIGIN" "$PATCH_BRANCH"
	info "pushed"
else
	cat <<-MSG

	    Not pushed. When you are happy with the result:

	        git push $ORIGIN $MIRROR_BRANCH
	        git push --force-with-lease $ORIGIN $PATCH_BRANCH

	    Teammates must then run: git fetch $ORIGIN && git rebase $ORIGIN/$PATCH_BRANCH
	MSG
fi

cat <<-MSG

	    Update the base tag recorded in ralim/README.md: $FROM_TAG -> $NEW_TAG
	    Undo this run:  $ROLLBACK
MSG

[ -z "$START_BRANCH" ] || [ "$START_BRANCH" = "$PATCH_BRANCH" ] || git checkout --quiet "$START_BRANCH"
