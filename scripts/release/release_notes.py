#!/usr/bin/env python3
"""Turns the commits since the previous release into release notes: HTML for the update feed (what the
update window shows) or Markdown for the GitHub release.

    release_notes.py                       # HTML, from the latest v* tag to HEAD
    release_notes.py --since v0.1.0 --markdown

Uses commit subjects only, skips merge commits and anything starting with "fixup!" or "WIP", and escapes
everything: a subject can't inject markup into the update window. Standard library only.
"""

import argparse
import html
import re
import subprocess
import sys

SKIPPED = re.compile(r"^(fixup!|squash!|wip\b)", re.IGNORECASE)


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def latest_tag():
    """The newest v* tag reachable from HEAD, or None before the first release."""
    result = subprocess.run(["git", "describe", "--tags", "--abbrev=0", "--match", "v*", "HEAD"],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip() or None


def subjects(since):
    revision = f"{since}..HEAD" if since else "HEAD"
    return [s for s in git("log", "--no-merges", "--pretty=%s", revision).splitlines() if s.strip() and not SKIPPED.match(s)]


def render_html(items):
    if not items:
        return "<p>Maintenance release.</p>"
    return "<ul>\n" + "\n".join(f"  <li>{html.escape(item)}</li>" for item in items) + "\n</ul>"


def render_markdown(items):
    if not items:
        return "Maintenance release."
    return "\n".join(f"- {item}" for item in items)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", help="the previous release's tag (default: the latest v* tag)")
    parser.add_argument("--markdown", action="store_true")
    args = parser.parse_args(argv)
    items = subjects(args.since if args.since is not None else latest_tag())
    print(render_markdown(items) if args.markdown else render_html(items))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
