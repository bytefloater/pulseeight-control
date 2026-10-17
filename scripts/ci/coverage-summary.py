#!/usr/bin/env python3
"""Summarises llvm-cov JSON as Markdown, for a CI job summary.

    swift test --enable-code-coverage --package-path PulseEightKit
    scripts/ci/coverage-summary.py "$(swift test --show-codecov-path --package-path PulseEightKit)" --title PulseEightKit

Test sources and build folders are left out, so the figure is the coverage of the code that ships. Only
reports; it never fails the build (there is no threshold until there is a baseline worth defending).
"""

import argparse
import json
import sys

# Anything under these folders isn't shipped code.
EXCLUDED = ("/Tests/", "/.build/", "/out/", "/checkouts/")


def summarise(report, excluded=EXCLUDED, include=()):
    """Returns (files, covered, total): files is [(name, covered, total)] for shipped code only.

    `include`, when given, keeps only files whose path contains one of the strings: a package's report also
    holds the sources of the local packages it depends on, which belong to those packages' own reports.
    """
    rows = []
    for entry in report.get("data", []):
        for file in entry.get("files", []):
            name = file["filename"]
            if any(part in name for part in excluded):
                continue
            if include and not any(part in name for part in include):
                continue
            lines = file["summary"]["lines"]
            rows.append((name, lines["covered"], lines["count"]))
    covered = sum(row[1] for row in rows)
    total = sum(row[2] for row in rows)
    return rows, covered, total


def percent(covered, total):
    return 100.0 * covered / total if total else 100.0


def shorten(name, strip):
    for prefix in strip:
        if prefix and prefix in name:
            return name.split(prefix, 1)[1]
    return name


def markdown(rows, covered, total, title, lowest, strip):
    out = [f"### Swift coverage: {title}" if title else "### Swift coverage", ""]
    out.append(f"**{percent(covered, total):.1f}%** of {total:,} lines ({len(rows)} files; tests excluded)")
    if rows and lowest:
        out += ["", f"Least covered files:", "", "| File | Lines covered | % |", "|---|---:|---:|"]
        worst = sorted(rows, key=lambda r: (percent(r[1], r[2]), -r[2]))[:lowest]
        for name, cov, count in worst:
            out.append(f"| `{shorten(name, strip)}` | {cov}/{count} | {percent(cov, count):.0f}% |")
    return "\n".join(out) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", help="llvm-cov JSON export (swift test --show-codecov-path)")
    parser.add_argument("--title", default="", help="heading, e.g. the package name")
    parser.add_argument("--lowest", type=int, default=8, help="how many least-covered files to list (0 for none)")
    parser.add_argument("--include", action="append", default=[],
                        help="only count files whose path contains this (repeatable), e.g. PulseEightKit/Sources")
    parser.add_argument("--strip", action="append", default=["PulseEightKit/", "PulseEightFakeServer/", "PulseEightControl-macos/"],
                        help="show file paths from after this folder name (repeatable)")
    args = parser.parse_args(argv)

    with open(args.report, encoding="utf-8") as handle:
        report = json.load(handle)
    rows, covered, total = summarise(report, include=args.include)
    sys.stdout.write(markdown(rows, covered, total, args.title, args.lowest, args.strip))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
