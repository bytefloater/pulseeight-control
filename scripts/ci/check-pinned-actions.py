#!/usr/bin/env python3
"""Checks that every third-party GitHub Action in the workflows is pinned to a commit that really is
the release its comment names.

A pin is `uses: owner/repo@<40-hex commit> # vX.Y.Z`. A mistyped or stale commit makes a workflow fail
at run time (or, worse, run something else), and nothing in YAML linting notices. This asks GitHub's
public git remotes, so it needs the network and no token.

    scripts/ci/check-pinned-actions.py            # checks .github/workflows/*.yml
    scripts/ci/check-pinned-actions.py FILE...
"""

import pathlib
import re
import subprocess
import sys

USES = re.compile(r"^\s*(?:-\s*)?uses:\s*(?P<action>[^\s#]+)\s*(?:#\s*(?P<comment>.*))?$")
PINNED = re.compile(r"^(?P<repo>[\w.-]+/[\w.-]+)(?P<path>/[^@]*)?@(?P<ref>[0-9a-f]{40})$")


def find_uses(text):
    """Yields (line number, action, comment) for each `uses:` line."""
    for number, line in enumerate(text.splitlines(), 1):
        match = USES.match(line)
        if match:
            yield number, match["action"], (match["comment"] or "").strip()


def remote_commits(repo, tag):
    """The commits a tag may legitimately point at: the tag itself and, for annotated tags, what it wraps."""
    out = subprocess.run(
        ["git", "ls-remote", f"https://github.com/{repo}.git", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
        capture_output=True, text=True, timeout=60, check=False,
    )
    return {line.split()[0] for line in out.stdout.splitlines() if line.strip()}


def check(text, lookup=remote_commits):
    """Returns a list of problems found in one workflow's text."""
    problems = []
    for number, action, comment in find_uses(text):
        if action.startswith("./") or action.startswith("docker://"):
            continue
        match = PINNED.match(action)
        if not match:
            problems.append(f"line {number}: {action} is not pinned to a commit")
            continue
        tag = comment.split()[0] if comment else ""
        if not tag:
            problems.append(f"line {number}: {action} has no version comment to check it against")
            continue
        commits = lookup(match["repo"], tag)
        if not commits:
            problems.append(f"line {number}: {match['repo']} has no tag {tag}")
        elif match["ref"] not in commits:
            problems.append(f"line {number}: {match['repo']}@{match['ref'][:12]} is not {tag} (that is {', '.join(sorted(c[:12] for c in commits))})")
    return problems


def main(argv):
    root = pathlib.Path(__file__).resolve().parents[2]
    files = [pathlib.Path(a) for a in argv] or sorted((root / ".github" / "workflows").glob("*.y*ml"))
    failed = False
    for path in files:
        problems = check(path.read_text(encoding="utf-8"))
        for problem in problems:
            print(f"{path.name}: {problem}", file=sys.stderr)
        failed = failed or bool(problems)
        if not problems:
            print(f"{path.name}: every action is pinned to the release its comment names")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
