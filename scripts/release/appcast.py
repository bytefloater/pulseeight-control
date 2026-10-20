#!/usr/bin/env python3
"""Builds and edits Sparkle-style update feeds (appcasts) for the macOS and Windows apps.

    appcast.py add FEED --version 0.2.0.300 --short 0.2.0 --url https://.../App-0.2.0.dmg --length 123456 \\
                        --signature BASE64 [--channel rc|beta] [--min-os 14.0] [--notes-file notes.html]
    appcast.py remove FEED --version 0.2.0.300     # yank a release: clients stop being offered it
    appcast.py validate FEED [--allow-http] [--strict]
    appcast.py show FEED

Sparkle compares sparkle:version (the build number), so it must increase with every release; the order of
items in the file doesn't matter to it, but this script keeps them newest first.

A pre-release carries `<sparkle:channel>` (rc or beta). Both Sparkle and NetSparkle offer an item with no channel to
everyone and an item with a channel only to apps that asked for that channel, so one feed holds every kind of release.

A version is only ever added once: adding one that is already there is an error unless --replace says that is the
intent (to correct a feed by hand). `validate --strict` (what the release workflow runs) also requires every item to
be one of this project's release versions (see version.py) with the channel and build number that version dictates.
Standard library only.
"""

import argparse
import base64
import email.utils
import datetime
import sys
import os
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import version as release_version  # noqa: E402  (the one definition of what a release version is)

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)


def s(tag):
    """A tag in the Sparkle namespace."""
    return f"{{{SPARKLE}}}{tag}"


class FeedError(Exception):
    pass


# --- reading and writing ---------------------------------------------------------------------------------


def new_feed(title, link="", description=""):
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    if link:
        ET.SubElement(channel, "link").text = link
    ET.SubElement(channel, "description").text = description or f"Updates for {title}"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def load(path):
    try:
        return ET.parse(path)
    except ET.ParseError as error:
        raise FeedError(f"{path} isn't well-formed XML: {error}") from error


def channel_of(tree):
    channel = tree.getroot().find("channel")
    if channel is None:
        raise FeedError("The feed has no <channel>.")
    return channel


def save(tree, path):
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n")


# --- versions --------------------------------------------------------------------------------------------


def version_key(text):
    """'12' or '1.2.3' as a tuple of integers, for ordering."""
    try:
        return tuple(int(part) for part in text.strip().split("."))
    except ValueError as error:
        raise FeedError(f"Version '{text}' isn't dotted numbers (like 12 or 1.2.3).") from error


def items(channel):
    return channel.findall("item")


def item_version(item):
    element = item.find(s("version"))
    if element is None or not (element.text or "").strip():
        raise FeedError("An item has no sparkle:version.")
    return element.text.strip()


# --- editing ---------------------------------------------------------------------------------------------


CHANNELS = ("rc", "beta")


def build_item(*, version, short, url, length, signature, min_os=None, os_name=None, notes=None,
               pub_date=None, signature_attribute="edSignature", title=None, channel=None):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = title or short
    ET.SubElement(item, "pubDate").text = pub_date or email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, s("version")).text = str(version)
    ET.SubElement(item, s("shortVersionString")).text = short
    if channel:
        if channel not in CHANNELS:
            raise FeedError(f"Channel '{channel}' isn't one of {', '.join(CHANNELS)} (a release has no channel).")
        ET.SubElement(item, s("channel")).text = channel
    if min_os:
        ET.SubElement(item, s("minimumSystemVersion")).text = min_os
    if notes:
        ET.SubElement(item, "description").text = notes
    attributes = {"url": url, "length": str(length), "type": "application/octet-stream", s(signature_attribute): signature}
    if os_name:
        attributes[s("os")] = os_name
    ET.SubElement(item, "enclosure", attributes)
    return item


def add_item(tree, item, replace=False):
    """Puts `item` in and keeps newest first. A version that is already there is an error, unless `replace`."""
    channel = channel_of(tree)
    version = item_version(item)
    for existing in items(channel):
        if item_version(existing) == version:
            if not replace:
                raise FeedError(f"Version {version} is already in the feed. A release is only ever added once; "
                                f"pass --replace only to correct the feed by hand.")
            channel.remove(existing)
    channel.append(item)
    sort_items(channel)


def remove_version(tree, version):
    channel = channel_of(tree)
    found = [i for i in items(channel) if item_version(i) == version]
    if not found:
        raise FeedError(f"No item with version {version}.")
    for item in found:
        channel.remove(item)


def sort_items(channel):
    ordered = sorted(items(channel), key=lambda i: version_key(item_version(i)), reverse=True)
    for item in items(channel):
        channel.remove(item)
    for item in ordered:
        channel.append(item)


# --- checking --------------------------------------------------------------------------------------------


def problems(tree, allow_http=False):
    """Everything wrong with a feed, as readable sentences (empty means fine)."""
    found = []
    try:
        channel = channel_of(tree)
    except FeedError as error:
        return [str(error)]

    seen = set()
    versions = []
    for index, item in enumerate(items(channel), 1):
        label = f"item {index}"
        try:
            version = item_version(item)
            label = f"version {version}"
            versions.append(version_key(version))
        except FeedError as error:
            found.append(f"{label}: {error}")
            continue
        if version in seen:
            found.append(f"{label}: the version appears more than once")
        seen.add(version)

        if item.find(s("shortVersionString")) is None:
            found.append(f"{label}: no sparkle:shortVersionString")
        enclosure = item.find("enclosure")
        if enclosure is None:
            found.append(f"{label}: no <enclosure>")
            continue
        url = enclosure.get("url", "")
        if not (url.startswith("https://") or (allow_http and url.startswith("http://"))):
            found.append(f"{label}: the download URL must be https ({url or 'missing'})")
        length = enclosure.get("length", "")
        if not length.isdigit() or int(length) <= 0:
            found.append(f"{label}: the length must be the file's size in bytes ({length or 'missing'})")
        signature = enclosure.get(s("edSignature")) or enclosure.get(s("signature"))
        if not signature:
            found.append(f"{label}: no signature")
        else:
            try:
                if len(base64.b64decode(signature, validate=True)) != 64:
                    found.append(f"{label}: an Ed25519 signature is 64 bytes")
            except ValueError:
                found.append(f"{label}: the signature isn't base64")

    if versions != sorted(versions, reverse=True):
        found.append("the items aren't newest first")
    return found


def release_problems(tree):
    """What `validate --strict` adds: every item is one of this project's releases, with the channel and the build number
    that its version string dictates (version.py), so the feed can never disagree with what the apps report."""
    found = []
    try:
        channel = channel_of(tree)
    except FeedError:
        return found
    for item in items(channel):
        short = item.findtext(s("shortVersionString"), "").strip()
        label = f"{short or '?'}"
        parsed = release_version.parse_semver(short)
        if parsed is None:
            found.append(f"{label}: isn't a release version (expected 0.1.0, 0.1.0-rc.1 or 0.1.0-beta.1)")
            continue
        build = (item.findtext(s("version")) or "").strip()
        if build != parsed.build:
            found.append(f"{label}: sparkle:version is {build or 'missing'} but {short} must be {parsed.build}")
        declared = (item.findtext(s("channel")) or "").strip()
        expected = parsed.channel if parsed.is_prerelease else ""
        if declared != expected:
            found.append(f"{label}: its channel is '{declared or 'none'}' but it must be '{expected or 'none'}'")
    return found


# --- command line ----------------------------------------------------------------------------------------


def read_notes(args):
    if args.notes_file:
        with open(args.notes_file, encoding="utf-8") as handle:
            return handle.read().strip()
    return args.notes


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    add = sub.add_parser("add", help="add (or replace) a release")
    add.add_argument("feed")
    add.add_argument("--version", required=True, help="sparkle:version, the build number; must increase every release")
    add.add_argument("--short", required=True, help="the version people see, e.g. 0.2.0")
    add.add_argument("--url", required=True)
    add.add_argument("--length", required=True, type=int, help="size of the file in bytes")
    add.add_argument("--signature", required=True, help="base64 Ed25519 signature of the file")
    add.add_argument("--min-os", help="sparkle:minimumSystemVersion, e.g. 14.0")
    add.add_argument("--os", dest="os_name", help="sparkle:os on the enclosure, e.g. windows")
    add.add_argument("--signature-attribute", default="edSignature", choices=["edSignature", "signature"],
                     help="Sparkle reads edSignature; NetSparkle reads signature unless told otherwise")
    add.add_argument("--channel", choices=CHANNELS, help="rc or beta; leave out for a release (offered to everyone)")
    add.add_argument("--replace", action="store_true", help="replace the version if it is already in the feed (by-hand corrections only)")
    add.add_argument("--notes", help="release notes (plain text or HTML)")
    add.add_argument("--notes-file")
    add.add_argument("--pub-date", help="RFC 2822 date (default: now)")
    add.add_argument("--title", help="channel title when creating the feed")
    add.add_argument("--link", default="", help="channel link when creating the feed")

    remove = sub.add_parser("remove", help="remove a release")
    remove.add_argument("feed")
    remove.add_argument("--version", required=True)

    validate = sub.add_parser("validate", help="check a feed")
    validate.add_argument("feed")
    validate.add_argument("--allow-http", action="store_true", help="allow http:// download URLs (local testing only)")
    validate.add_argument("--strict", action="store_true",
                          help="also require release versions, with the channel and build number each one dictates")

    show = sub.add_parser("show", help="list the releases in a feed")
    show.add_argument("feed")

    args = parser.parse_args(argv)
    try:
        if args.command == "add":
            try:
                tree = load(args.feed)
            except FileNotFoundError:
                tree = new_feed(args.title or "PulseEight Control", args.link)
            add_item(tree, build_item(
                version=args.version, short=args.short, url=args.url, length=args.length, signature=args.signature,
                min_os=args.min_os, os_name=args.os_name, notes=read_notes(args), pub_date=args.pub_date,
                signature_attribute=args.signature_attribute, channel=args.channel), replace=args.replace)
            save(tree, args.feed)
            print(f"{args.feed}: version {args.version} ({args.short}) added")
        elif args.command == "remove":
            tree = load(args.feed)
            remove_version(tree, args.version)
            save(tree, args.feed)
            print(f"{args.feed}: version {args.version} removed")
        elif args.command == "validate":
            tree = load(args.feed)
            found = problems(tree, allow_http=args.allow_http) + (release_problems(tree) if args.strict else [])
            for problem in found:
                print(f"{args.feed}: {problem}", file=sys.stderr)
            if found:
                return 1
            print(f"{args.feed}: ok")
        elif args.command == "show":
            for item in items(channel_of(load(args.feed))):
                enclosure = item.find("enclosure")
                channel = item.findtext(s("channel"), "")
                print(f"{item_version(item):>12}  {item.findtext(s('shortVersionString'), '?'):<14} {channel or 'release':<8} "
                      f"{enclosure.get('url') if enclosure is not None else ''}")
    except (FeedError, FileNotFoundError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
