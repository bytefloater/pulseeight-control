#!/usr/bin/env python3
"""The one place that knows what a release version is.

A release is named by its tag, and only by its tag. Nothing else in the repository holds a version number.

    v0.1.0            PulseEight Control 0.1.0: Release
    v0.1.0.rc-01      PulseEight Control 0.1.0: Release Candidate 1
    v0.1.0.beta-01    PulseEight Control 0.1.0: Beta 1

Only that spelling is accepted (two digit numbers, 01 to 99), so one release can't be named two ways and so released twice.

    version.py fields TAG [--github-output FILE]     everything derived from the tag, one name=value per line
    version.py check TAG --feed appcast.xml ...      can this release be made? (the gate before anything is built)
    version.py previous TAG --tags FILE              the tag its release notes start from
    version.py dev                                   the fields of a development build (no tag)

From a tag:

    semver   0.1.0-rc.1   file names, CFBundleShortVersionString, the feed's shortVersionString
    build    0.1.0.201    what an updater compares (CFBundleVersion, sparkle:version, the Windows file version)
    channel  rc           the feed's sparkle:channel (a release has none), and the pre-release flag
    label    Release Candidate 1

`build` is M.m.p.R with R = beta 100+N, release candidate 200+N, release 300: within a version a beta is older than a
release candidate, which is older than the release, and `M.m.p` orders versions. It is always the same for the same tag, so
a re-run can't change it and two releases can't share one, and it fits Windows' four 16-bit version numbers.

Standard library only.
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from typing import List, NamedTuple, Optional, Tuple

PRODUCT = "PulseEight Control"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"

# Order of the channels within one version: a beta comes before a release candidate, which comes before the release.
RANKS = {"beta": 0, "rc": 1, "release": 2}
BUILD_BASE = {"beta": 100, "rc": 200, "release": 300}
LABELS = {"beta": "Beta", "rc": "Release Candidate", "release": "Release"}
SEMVER_NAMES = {"beta": "beta", "rc": "rc"}

NUMBER = r"(0|[1-9]\d{0,3})"
TAG = re.compile(rf"^v{NUMBER}\.{NUMBER}\.{NUMBER}(?:\.(rc|beta)-(0[1-9]|[1-9]\d))?$")
SEMVER = re.compile(rf"^{NUMBER}\.{NUMBER}\.{NUMBER}(?:-(rc|beta)\.([1-9]\d?))?$")


class VersionError(Exception):
    pass


class Version(NamedTuple):
    major: int
    minor: int
    patch: int
    channel: str = "release"
    number: int = 0  # the 1 of rc-01; 0 for a release

    @property
    def core(self) -> Tuple[int, int, int]:
        return (self.major, self.minor, self.patch)

    @property
    def is_prerelease(self) -> bool:
        return self.channel != "release"

    @property
    def sort_key(self) -> Tuple[int, int, int, int, int]:
        return (self.major, self.minor, self.patch, RANKS[self.channel], self.number)

    @property
    def version(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    @property
    def tag(self) -> str:
        return f"v{self.version}" + (f".{self.channel}-{self.number:02d}" if self.is_prerelease else "")

    @property
    def semver(self) -> str:
        return self.version + (f"-{SEMVER_NAMES[self.channel]}.{self.number}" if self.is_prerelease else "")

    @property
    def build(self) -> str:
        return f"{self.version}.{BUILD_BASE[self.channel] + self.number}"

    @property
    def label(self) -> str:
        return LABELS[self.channel] + (f" {self.number}" if self.is_prerelease else "")

    @property
    def title(self) -> str:
        return f"{PRODUCT} {self.version}: {self.label}"


def parse_tag(tag: str) -> Version:
    """A tag as a Version, or a VersionError saying what the accepted spelling is."""
    match = TAG.fullmatch(tag)  # exactly the canonical spelling: no trimming, no trailing newline
    if not match:
        raise VersionError(
            f"'{tag}' isn't a release tag. The accepted forms are v0.1.0, v0.1.0.rc-01 (release candidate 1) and "
            f"v0.1.0.beta-01 (beta 1): numbers without leading zeros, and a two digit 01 to 99 after rc- or beta-.")
    major, minor, patch, channel, number = match.groups()
    return Version(int(major), int(minor), int(patch), channel or "release", int(number) if number else 0)


def parse_semver(text: str) -> Optional[Version]:
    """A feed's shortVersionString (0.1.0 or 0.1.0-rc.1) as a Version; None if it isn't one of ours."""
    match = SEMVER.match(text.strip())
    if not match:
        return None
    major, minor, patch, channel, number = match.groups()
    return Version(int(major), int(minor), int(patch), channel or "release", int(number) if number else 0)


# The fields of a build that isn't a release: Info.plist, the csproj and the scripts all take their defaults from here.
DEV = {"version": "0.0.0", "semver": "0.0.0-dev", "build": "0.0.0.0", "channel": "dev", "label": "Development build",
       "title": f"{PRODUCT} (development build)", "tag": "", "prerelease": "false"}


def fields(version: Version) -> dict:
    return {
        "version": version.version, "semver": version.semver, "build": version.build, "channel": version.channel,
        "label": version.label, "title": version.title, "tag": version.tag,
        "prerelease": "true" if version.is_prerelease else "false",
    }


# --- what has been released ----------------------------------------------------------------------------------


def released_in_feed(path: str) -> List[Version]:
    """The versions an appcast offers. An item that isn't one of ours (an older naming) is skipped."""
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as error:
        raise VersionError(f"{path} isn't well-formed XML: {error}") from error
    found = []
    for item in root.iter("item"):
        short = item.findtext(f"{{{SPARKLE}}}shortVersionString", "")
        version = parse_semver(short)
        if version:
            found.append(version)
    return found


def check(candidate: Version, released: List[Version], allow_older: bool = False) -> List[str]:
    """Why `candidate` can't be released, as sentences (empty means it can). `released` is every version a feed offers.

    A version is released once a feed offers it: that is what installed apps see. A GitHub release that never reached a
    feed is a run that stopped half way, and re-running it is how it is finished.
    """
    problems = []
    if candidate in released:
        problems.append(f"{candidate.tag} is already released: it is in the update feed. A version can only be released once; "
                        f"use the next one (a new tag).")
        return problems

    finals = sorted(v for v in released if not v.is_prerelease)
    newest_final = finals[-1] if finals else None

    if candidate.is_prerelease and any(v.core == candidate.core for v in finals):
        problems.append(f"{candidate.version} is already released, so there can't be a {candidate.label.lower()} of it any more.")
    if newest_final and candidate.core < newest_final.core and not allow_older:
        problems.append(
            f"{candidate.tag} is older than {newest_final.tag}, which is already released: updaters would never offer it. "
            f"(To really publish an older line, re-run with the allow-older input.)")

    same = [v for v in released if v.core == candidate.core and v.is_prerelease]
    if candidate.is_prerelease:
        later_channel = [v for v in same if RANKS[v.channel] > RANKS[candidate.channel]]
        if later_channel:
            problems.append(f"{later_channel[0].tag} is already released, which comes after a {candidate.label.lower()} of "
                            f"{candidate.version}.")
        same_channel = [v for v in same if v.channel == candidate.channel]
        highest = max((v.number for v in same_channel), default=0)
        if candidate.number <= highest:
            problems.append(f"{candidate.tag} must be higher than the {candidate.channel} already released "
                            f"({Version(*candidate.core, candidate.channel, highest).tag}).")
    return problems


def previous_tag(candidate: Version, tags: List[str]) -> Optional[str]:
    """Where `candidate`'s release notes start. A release lists everything since the previous release (so it includes the
    release candidates' changes); a pre-release lists what is new since the previous tag of any kind."""
    versions = []
    for tag in tags:
        try:
            versions.append(parse_tag(tag))
        except VersionError:
            continue  # an old-style or unrelated tag
    older = [v for v in versions if v.sort_key < candidate.sort_key]
    if not candidate.is_prerelease:
        older = [v for v in older if not v.is_prerelease]
    return max(older, key=lambda v: v.sort_key).tag if older else None


# --- command line --------------------------------------------------------------------------------------------


def emit(values: dict, output: Optional[str]) -> None:
    lines = [f"{name}={value}" for name, value in values.items()]
    print("\n".join(lines))
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    fields_cmd = sub.add_parser("fields", help="everything derived from a tag")
    fields_cmd.add_argument("tag")
    fields_cmd.add_argument("--github-output", help="also append the fields to this file (GITHUB_OUTPUT)")

    check_cmd = sub.add_parser("check", help="can this tag be released?")
    check_cmd.add_argument("tag")
    check_cmd.add_argument("--feed", action="append", default=[], help="an appcast listing what is released (repeatable)")
    check_cmd.add_argument("--allow-older", action="store_true", help="allow a version older than the newest release")

    previous_cmd = sub.add_parser("previous", help="the tag the release notes start from")
    previous_cmd.add_argument("tag")
    previous_cmd.add_argument("--tags", required=True, help="a file with one existing tag per line")

    dev_cmd = sub.add_parser("dev", help="the fields of a development build")
    dev_cmd.add_argument("--github-output")

    args = parser.parse_args(argv)
    try:
        if args.command == "dev":
            emit(DEV, args.github_output)
        elif args.command == "fields":
            emit(fields(parse_tag(args.tag)), args.github_output)
        elif args.command == "check":
            candidate = parse_tag(args.tag)
            released = [v for path in args.feed for v in released_in_feed(path)]
            problems = check(candidate, released, args.allow_older)
            for problem in problems:
                print(f"error: {problem}", file=sys.stderr)
            if problems:
                return 1
            print(f"{candidate.tag}: ok ({candidate.title}; build {candidate.build})")
        elif args.command == "previous":
            with open(args.tags, encoding="utf-8") as handle:
                tags = [line.strip() for line in handle if line.strip()]
            print(previous_tag(parse_tag(args.tag), tags) or "")
    except (VersionError, FileNotFoundError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
