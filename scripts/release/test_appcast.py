"""Tests for appcast.py. Run:  python3 -m unittest discover -s scripts/release -p 'test_*.py'"""

import base64
import contextlib
import importlib.util
import io
import os
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("appcast", pathlib.Path(__file__).with_name("appcast.py"))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)

SIGNATURE = base64.b64encode(bytes(range(64))).decode()
DATE = "Sat, 17 Oct 2026 12:00:00 +0000"


def item(version, short=None, **overrides):
    values = dict(version=version, short=short or f"0.{version}.0", url=f"https://example.com/app-{version}.dmg",
                  length=1000 + len(version), signature=SIGNATURE, min_os="14.0", pub_date=DATE)
    values.update(overrides)
    return appcast.build_item(**values)


def feed_with(*versions):
    tree = appcast.new_feed("Test App")
    for version in versions:
        appcast.add_item(tree, item(version))
    return tree


def versions_of(tree):
    return [appcast.item_version(i) for i in appcast.items(appcast.channel_of(tree))]


class EditingTests(unittest.TestCase):
    def test_a_new_release_carries_everything_sparkle_needs(self):
        tree = feed_with("3")
        xml = ET.tostring(tree.getroot(), encoding="unicode")
        self.assertIn("<sparkle:version>3</sparkle:version>", xml)
        self.assertIn("<sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>", xml)
        self.assertIn("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>", xml)
        self.assertIn('sparkle:edSignature="', xml)
        self.assertIn('length="1001"', xml)
        self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', xml)

    def test_items_are_kept_newest_first_whatever_the_order_added(self):
        self.assertEqual(versions_of(feed_with("2", "10", "1", "9")), ["10", "9", "2", "1"])

    def test_dotted_versions_compare_numerically_not_as_text(self):
        self.assertEqual(versions_of(feed_with("1.9", "1.10", "1.2")), ["1.10", "1.9", "1.2"])

    def test_adding_a_version_that_is_already_there_is_an_error(self):
        tree = feed_with("1", "2")
        with self.assertRaises(appcast.FeedError) as caught:
            appcast.add_item(tree, item("2", url="https://example.com/rebuilt.dmg"))
        self.assertIn("already in the feed", str(caught.exception))
        self.assertEqual(versions_of(tree), ["2", "1"])
        enclosure = appcast.items(appcast.channel_of(tree))[0].find("enclosure")
        self.assertNotEqual(enclosure.get("url"), "https://example.com/rebuilt.dmg", "nothing was changed")

    def test_replace_is_the_by_hand_way_to_correct_a_version(self):
        tree = feed_with("1", "2")
        appcast.add_item(tree, item("2", url="https://example.com/rebuilt.dmg"), replace=True)
        self.assertEqual(versions_of(tree), ["2", "1"])
        enclosure = appcast.items(appcast.channel_of(tree))[0].find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://example.com/rebuilt.dmg")

    def test_removing_a_version_yanks_only_that_one(self):
        tree = feed_with("1", "2", "3")
        appcast.remove_version(tree, "2")
        self.assertEqual(versions_of(tree), ["3", "1"])

    def test_removing_a_version_that_is_not_there_is_an_error(self):
        with self.assertRaises(appcast.FeedError):
            appcast.remove_version(feed_with("1"), "7")

    def test_windows_feeds_can_use_their_own_attributes(self):
        tree = appcast.new_feed("Win")
        appcast.add_item(tree, item("1", os_name="windows", signature_attribute="signature", min_os=None))
        xml = ET.tostring(tree.getroot(), encoding="unicode")
        self.assertIn('sparkle:os="windows"', xml)
        self.assertIn('sparkle:signature="', xml)
        self.assertNotIn("edSignature", xml)
        self.assertNotIn("minimumSystemVersion", xml)

    def test_notes_are_escaped_so_they_cannot_break_the_feed(self):
        tree = appcast.new_feed("T")
        appcast.add_item(tree, item("1", notes="Fixes <b>things</b> & ]]> more — café"))
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "feed.xml")
            appcast.save(tree, path)
            reloaded = appcast.load(path)
        description = appcast.items(appcast.channel_of(reloaded))[0].findtext("description")
        self.assertEqual(description, "Fixes <b>things</b> & ]]> more — café")


class FilesTests(unittest.TestCase):
    def run_cli(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return appcast.main(list(args))

    def test_the_command_line_builds_a_valid_feed_and_refuses_a_second_add(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "appcast.xml")
            common = ["--short", "0.2.0", "--url", "https://example.com/a.dmg", "--length", "5", "--signature", SIGNATURE,
                      "--pub-date", DATE, "--min-os", "14.0", "--title", "My App"]
            self.assertEqual(self.run_cli("add", path, "--version", "2", *common), 0)
            first = pathlib.Path(path).read_bytes()
            self.assertEqual(self.run_cli("add", path, "--version", "2", *common), 1)
            self.assertEqual(pathlib.Path(path).read_bytes(), first, "a refused add must not change the feed")
            self.assertEqual(self.run_cli("add", path, "--version", "2", "--replace", *common), 0)
            self.assertEqual(pathlib.Path(path).read_bytes(), first, "replacing with the same data changes nothing")
            self.assertEqual(self.run_cli("validate", path), 0)
            self.assertTrue(first.startswith(b"<?xml"))

    def test_a_malformed_file_is_reported_not_crashed_on(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "bad.xml")
            pathlib.Path(path).write_text("<rss><channel>", encoding="utf-8")
            self.assertEqual(self.run_cli("validate", path), 1)


class ValidationTests(unittest.TestCase):
    def test_a_good_feed_has_no_problems(self):
        self.assertEqual(appcast.problems(feed_with("1", "2")), [])

    def test_plain_http_is_refused_unless_allowed(self):
        tree = appcast.new_feed("T")
        appcast.add_item(tree, item("1", url="http://example.com/a.dmg"))
        self.assertTrue(any("https" in p for p in appcast.problems(tree)))
        self.assertEqual(appcast.problems(tree, allow_http=True), [])

    def test_a_signature_of_the_wrong_size_or_not_base64_is_caught(self):
        for bad, wanted in [(base64.b64encode(b"short").decode(), "64 bytes"), ("not base64!!", "base64")]:
            tree = appcast.new_feed("T")
            appcast.add_item(tree, item("1", signature=bad))
            self.assertTrue(any(wanted in p for p in appcast.problems(tree)), bad)

    def test_a_zero_or_missing_length_is_caught(self):
        tree = appcast.new_feed("T")
        appcast.add_item(tree, item("1", length=0))
        self.assertTrue(any("length" in p for p in appcast.problems(tree)))

    def test_duplicates_and_wrong_order_are_caught(self):
        tree = feed_with("1", "2")
        channel = appcast.channel_of(tree)
        channel.append(item("2"))
        self.assertTrue(any("more than once" in p for p in appcast.problems(tree)))

        tree = feed_with("1", "2")
        channel = appcast.channel_of(tree)
        first = appcast.items(channel)[0]
        channel.remove(first)
        channel.append(first)  # oldest-last order broken: 2 now after 1
        self.assertTrue(any("newest first" in p for p in appcast.problems(tree)))

    def test_a_version_that_is_not_numeric_is_caught(self):
        tree = appcast.new_feed("T")
        appcast.channel_of(tree).append(item("1", ))
        appcast.channel_of(tree).find("item").find(appcast.s("version")).text = "1.0-beta"
        self.assertTrue(any("dotted numbers" in p for p in appcast.problems(tree)))


class ChannelTests(unittest.TestCase):
    def test_a_pre_release_item_names_its_channel_and_a_release_names_none(self):
        rc = ET.tostring(item("0.1.0.201", short="0.1.0-rc.1", channel="rc"), encoding="unicode")
        release = ET.tostring(item("0.1.0.300", short="0.1.0"), encoding="unicode")
        self.assertIn("<sparkle:channel>rc</sparkle:channel>", rc)
        self.assertNotIn("sparkle:channel", release)

    def test_only_rc_and_beta_are_channels(self):
        with self.assertRaises(appcast.FeedError):
            item("0.1.0.300", short="0.1.0", channel="release")
        with self.assertRaises(appcast.FeedError):
            item("0.1.0.300", short="0.1.0", channel="nightly")

    def feed(self, *entries):
        tree = appcast.new_feed("T")
        for build, short, channel in entries:
            appcast.add_item(tree, item(build, short=short, channel=channel))
        return tree

    def test_one_feed_keeps_every_channel_newest_first(self):
        tree = self.feed(("0.1.0.201", "0.1.0-rc.1", "rc"), ("0.1.0.300", "0.1.0", None), ("0.1.0.101", "0.1.0-beta.1", "beta"))
        self.assertEqual(versions_of(tree), ["0.1.0.300", "0.1.0.201", "0.1.0.101"])
        self.assertEqual(appcast.problems(tree), [])

    def test_strict_validation_accepts_what_the_workflow_produces(self):
        tree = self.feed(("0.1.0.300", "0.1.0", None), ("0.1.0.201", "0.1.0-rc.1", "rc"), ("0.1.0.107", "0.1.0-beta.7", "beta"))
        self.assertEqual(appcast.release_problems(tree), [])

    def test_strict_validation_catches_a_build_number_that_does_not_match_the_version(self):
        problems = appcast.release_problems(self.feed(("0.1.0.250", "0.1.0-rc.1", "rc")))
        self.assertTrue(any("must be 0.1.0.201" in p for p in problems), problems)

    def test_strict_validation_catches_a_wrong_or_missing_channel(self):
        self.assertTrue(any("must be 'rc'" in p for p in appcast.release_problems(self.feed(("0.1.0.201", "0.1.0-rc.1", None)))))
        self.assertTrue(any("must be 'none'" in p for p in appcast.release_problems(self.feed(("0.1.0.300", "0.1.0", "beta")))))

    def test_strict_validation_refuses_a_version_that_is_not_ours(self):
        problems = appcast.release_problems(self.feed(("12", "0.12.0-nightly", None)))
        self.assertTrue(any("isn't a release version" in p for p in problems), problems)

    def test_the_command_line_adds_a_channel_and_validates_strictly(self):
        import io
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "appcast.xml")
            common = ["--url", "https://example.com/a.dmg", "--length", "5", "--signature", SIGNATURE, "--pub-date", DATE]
            def run(*args):
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    return appcast.main(list(args))
            self.assertEqual(run("add", path, "--version", "0.1.0.201", "--short", "0.1.0-rc.1", "--channel", "rc", *common), 0)
            self.assertEqual(run("add", path, "--version", "0.1.0.300", "--short", "0.1.0", *common), 0)
            self.assertEqual(run("validate", path, "--strict"), 0)
            self.assertIn("<sparkle:channel>rc</sparkle:channel>", pathlib.Path(path).read_text())
            self.assertEqual(run("add", path, "--version", "0.1.0.201", "--short", "0.1.0-rc.1", "--channel", "rc", *common), 1)


if __name__ == "__main__":
    unittest.main()
