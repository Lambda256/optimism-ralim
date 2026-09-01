#!/usr/bin/env python3
"""Claude Code PreToolUse hook (Bash): refuse shell commands that would push to,
or open/modify a pull request on, ethereum-optimism/optimism. Read-only `gh`
access to upstream stays allowed. Wired up in .claude/settings.json.

Reads the tool-call JSON on stdin; exit 2 blocks the call and shows stderr to the
agent, any other exit code lets it through. See ralim/README.md.
"""

import json
import re
import sys

UPSTREAM = r"ethereum-optimism/optimism"

# `git`/`gh` only counts when it starts a command, so that merely *mentioning*
# one of these commands in a commit message or a doc doesn't trip the hook.
CMD_START = r"(?:^|[\n;|&]|\$\(|`|\bthen\s+|\bdo\s+|\bxargs\s+)\s*(?:sudo\s+)?"

HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def strip_heredocs(cmd: str) -> str:
    """Drop heredoc bodies — they are data (commit messages, file contents), not
    commands, and they routinely quote the very commands this hook blocks."""
    out, rest = [], cmd
    while True:
        m = HEREDOC.search(rest)
        if not m:
            out.append(rest)
            return "".join(out)
        delim = m.group(2)
        nl = rest.find("\n", m.end())
        out.append(rest[: m.end()])
        if nl == -1:
            return "".join(out)
        body = rest[nl + 1 :]
        end = re.search(rf"^\s*{re.escape(delim)}\s*$", body, re.MULTILINE)
        rest = body[end.end() :] if end else ""


def blocks(cmd: str) -> bool:
    if not re.search(UPSTREAM, cmd) and not re.search(r"\bupstream\b", cmd):
        return False  # nothing here refers to upstream at all

    # Pushing: either the 'upstream' remote by name, or any upstream URL.
    if re.search(
        CMD_START + r"git\s+(?:-\S+\s+|--\S+(?:[= ]\S+)?\s+)*push\b", cmd
    ) and (
        re.search(r"\bpush\b[^&|;\n]*\bupstream\b", cmd) or re.search(UPSTREAM, cmd)
    ):
        return True

    # Writing to a PR or issue on upstream through gh.
    if re.search(
        CMD_START + r"gh\s+(?:pr|issue)\s+"
        r"(?:create|edit|merge|comment|review|close|reopen|ready)\b",
        cmd,
    ) and re.search(UPSTREAM, cmd):
        return True

    # The same writes through the raw API.
    if re.search(
        CMD_START + r"gh\s+api\b[^&|;\n]*(?:-X|--method)[= ]*(?:POST|PATCH|PUT|DELETE)",
        cmd,
        re.IGNORECASE,
    ) and re.search(rf"repos/{UPSTREAM}/(?:pulls|issues)", cmd):
        return True

    return False


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # never block because the hook itself failed to parse input

    cmd = (payload.get("tool_input") or {}).get("command") or ""
    if not cmd or not blocks(strip_heredocs(cmd)):
        return 0

    print(
        "Blocked by ralim fork policy: this clone must never push to, or open a "
        "PR on, ethereum-optimism/optimism.\n"
        "Target Lambda256/optimism-ralim with base branch 'ralim' instead, e.g. "
        "`gh pr create --repo Lambda256/optimism-ralim --base ralim`.\n"
        "See ralim/README.md.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
