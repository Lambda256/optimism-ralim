#!/usr/bin/env python3
"""Cases for block-upstream-pr.py. Run: python3 ralim/hooks/test-block-upstream-pr.py

The hook is the last line of defense against an agent pushing or opening a PR on
ethereum-optimism/optimism, so it has to block the real commands while leaving
read-only upstream access — and mere mentions of a blocked command inside commit
messages or file contents — alone.
"""

import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location(
    "hook", pathlib.Path(__file__).with_name("block-upstream-pr.py")
)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

MUST_BLOCK = [
    "git push upstream ralim",
    "git push --dry-run upstream ralim",
    "git push -f upstream HEAD:develop",
    "git push https://github.com/ethereum-optimism/optimism.git HEAD:develop",
    "gh pr create --repo ethereum-optimism/optimism --base develop --title x",
    "cd /tmp && gh pr create -R ethereum-optimism/optimism --fill",
    "gh pr edit 42 --repo ethereum-optimism/optimism --add-label x",
    "gh api -X POST repos/ethereum-optimism/optimism/pulls -f title=x",
    "gh api --method PATCH repos/ethereum-optimism/optimism/issues/1 -f state=closed",
]

MUST_ALLOW = [
    "git push origin ralim",
    "git push",
    "git push origin HEAD --force-with-lease",
    "git fetch upstream develop",
    "git log upstream/develop --oneline",
    "git merge --ff-only upstream/develop",
    "gh pr create --repo Lambda256/optimism-ralim --base ralim --fill",
    "gh pr view 123 --repo ethereum-optimism/optimism",
    "gh pr list --repo ethereum-optimism/optimism --state open",
    "gh api repos/ethereum-optimism/optimism/pulls/123",
    # A mention inside data, not a command:
    "git commit -F - <<'EOF'\nblock PRs to ethereum-optimism/optimism\ndon't run `gh pr create --repo ethereum-optimism/optimism`\nEOF",
    "cat > notes.md <<'EOF'\ngit push upstream main\nEOF",
]


def main() -> int:
    failures = []
    for cmd in MUST_BLOCK:
        if not hook.blocks(hook.strip_heredocs(cmd)):
            failures.append(f"should block but allowed: {cmd}")
    for cmd in MUST_ALLOW:
        if hook.blocks(hook.strip_heredocs(cmd)):
            failures.append(f"should allow but blocked: {cmd}")

    for f in failures:
        print(f, file=sys.stderr)
    total = len(MUST_BLOCK) + len(MUST_ALLOW)
    print(f"{total - len(failures)}/{total} cases pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
