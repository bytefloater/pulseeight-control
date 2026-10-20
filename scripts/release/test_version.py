import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import version as v  # noqa: E402


def feed(*shorts):
    """An appcast offering the given shortVersionStrings."""
    items = "".join(
        f'<item><sparkle:shortVersionString>{s}</sparkle:shortVersionString></item>' for s in shorts)
    return ('<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f"<channel>{items}</channel></rss>")


class TagGrammarTests(unittest.TestCase):
    def test_the_three_forms_in_the_spec(self):
        self.assertEqual(v.parse_tag("v0.1.0"), v.Version(0, 1, 0, "release", 0))
        self.assertEqual(v.parse_tag("v0.1.0.rc-01"), v.Version(0, 1, 0, "rc", 1))
        self.assertEqual(v.parse_tag("v0.1.0.beta-12"), v.Version(0, 1, 0, "beta", 12))

    def test_only_the_canonical_spelling_is_accepted(self):
        for bad in [
            "0.1.0", "v0.1", "v0.1.0.1", "V0.1.0", "v0.1.0 ", "v01.1.0", "v0.1.0-rc.1", "v0.1.0.rc.1", "v0.1.0.rc-1",
            "v0.1.0.rc-001", "v0.1.0.rc-00", "v0.1.0.rc-100", "v0.1.0.alpha-01", "v0.1.0.rc", "v0.1.0.RC-01",
            "v0.1.0.rc-01.extra", "v10000.0.0", "v0.1.0+build", "", "v",
        ]:
            with self.subTest(bad=bad), self.assertRaises(v.VersionError):
                v.parse_tag(bad)

    def test_the_error_names_the_accepted_forms(self):
        with self.assertRaises(v.VersionError) as caught:
            v.parse_tag("v0.1.0.rc-1")
        self.assertIn("v0.1.0.rc-01", str(caught.exception))

    def test_a_tag_round_trips(self):
        for tag in ["v0.1.0", "v2.10.3", "v0.1.0.rc-01", "v1.0.0.beta-99", "v9999.9999.9999"]:
            self.assertEqual(v.parse_tag(tag).tag, tag)


class FieldTests(unittest.TestCase):
    def test_a_release(self):
        f = v.fields(v.parse_tag("v0.1.0"))
        self.assertEqual(f, {
            "version": "0.1.0", "semver": "0.1.0", "build": "0.1.0.300", "channel": "release", "label": "Release",
            "title": "PulseEight Control 0.1.0: Release", "tag": "v0.1.0", "prerelease": "false"})

    def test_a_release_candidate(self):
        f = v.fields(v.parse_tag("v0.1.0.rc-01"))
        self.assertEqual(f["semver"], "0.1.0-rc.1")
        self.assertEqual(f["build"], "0.1.0.201")
        self.assertEqual(f["channel"], "rc")
        self.assertEqual(f["label"], "Release Candidate 1")
        self.assertEqual(f["title"], "PulseEight Control 0.1.0: Release Candidate 1")
        self.assertEqual(f["prerelease"], "true")

    def test_a_beta(self):
        f = v.fields(v.parse_tag("v0.1.0.beta-07"))
        self.assertEqual((f["semver"], f["build"], f["label"]), ("0.1.0-beta.7", "0.1.0.107", "Beta 7"))
        self.assertEqual(f["title"], "PulseEight Control 0.1.0: Beta 7")

    def test_the_build_orders_releases_the_way_an_updater_must_see_them(self):
        order = ["v0.1.0.beta-01", "v0.1.0.beta-02", "v0.1.0.beta-99", "v0.1.0.rc-01", "v0.1.0.rc-02", "v0.1.0",
                 "v0.1.1.beta-01", "v0.1.1", "v0.2.0.beta-01", "v0.2.0", "v1.0.0.rc-01", "v1.0.0"]
        builds = [tuple(int(p) for p in v.parse_tag(t).build.split(".")) for t in order]
        self.assertEqual(builds, sorted(builds), "build numbers must rise in release order")
        self.assertEqual(len(set(builds)), len(builds), "and never repeat")

    def test_the_build_fits_windows_four_16_bit_numbers(self):
        biggest = v.parse_tag("v9999.9999.9999.rc-99")
        self.assertTrue(all(int(part) <= 65535 for part in biggest.build.split(".")))

    def test_the_semver_is_what_a_feed_reads_back(self):
        for tag in ["v0.1.0", "v0.1.0.rc-01", "v3.4.5.beta-10"]:
            version = v.parse_tag(tag)
            self.assertEqual(v.parse_semver(version.semver), version)

    def test_a_development_build_has_a_name_of_its_own(self):
        self.assertEqual(v.DEV["semver"], "0.0.0-dev")
        self.assertEqual(v.DEV["build"], "0.0.0.0")
        self.assertIsNone(v.parse_semver(v.DEV["semver"]), "it can never be mistaken for a release")


class CheckTests(unittest.TestCase):
    def problems(self, tag, released, **kwargs):
        return v.check(v.parse_tag(tag), [v.parse_semver(r) for r in released], **kwargs)

    def test_the_first_release_is_fine(self):
        self.assertEqual(self.problems("v0.1.0.beta-01", []), [])
        self.assertEqual(self.problems("v0.1.0", []), [])

    def test_a_version_cannot_be_released_twice(self):
        for tag, released in [("v0.1.0", "0.1.0"), ("v0.1.0.rc-01", "0.1.0-rc.1"), ("v0.1.0.beta-03", "0.1.0-beta.3")]:
            with self.subTest(tag=tag):
                problems = self.problems(tag, [released])
                self.assertEqual(len(problems), 1)
                self.assertIn("already released", problems[0])

    def test_the_normal_progression_is_accepted(self):
        self.assertEqual(self.problems("v0.1.0.beta-02", ["0.1.0-beta.1"]), [])
        self.assertEqual(self.problems("v0.1.0.rc-01", ["0.1.0-beta.1", "0.1.0-beta.2"]), [])
        self.assertEqual(self.problems("v0.1.0.rc-02", ["0.1.0-beta.2", "0.1.0-rc.1"]), [])
        self.assertEqual(self.problems("v0.1.0", ["0.1.0-beta.2", "0.1.0-rc.1", "0.1.0-rc.2"]), [])
        self.assertEqual(self.problems("v0.2.0.beta-01", ["0.1.0", "0.1.0-rc.1"]), [])

    def test_no_pre_release_of_a_version_already_released(self):
        problems = self.problems("v0.1.0.rc-02", ["0.1.0-rc.1", "0.1.0"])
        self.assertTrue(any("0.1.0 is already released" in p for p in problems), problems)

    def test_numbers_within_a_channel_must_rise(self):
        problems = self.problems("v0.1.0.rc-01", ["0.1.0-rc.2"])
        self.assertTrue(any("must be higher" in p for p in problems), problems)
        self.assertTrue(any("rc-02" in p for p in problems), "it names the one already released")

    def test_a_beta_cannot_follow_a_release_candidate(self):
        problems = self.problems("v0.1.0.beta-05", ["0.1.0-rc.1"])
        self.assertTrue(any("comes after" in p for p in problems), problems)

    def test_an_older_version_than_the_newest_release_is_refused_unless_allowed(self):
        problems = self.problems("v0.1.1", ["0.2.0"])
        self.assertTrue(any("older than v0.2.0" in p for p in problems), problems)
        self.assertEqual(self.problems("v0.1.1", ["0.2.0"], allow_older=True), [])

    def test_other_versions_pre_releases_do_not_count(self):
        self.assertEqual(self.problems("v0.2.0.rc-01", ["0.1.0", "0.1.0-rc.5", "0.1.5-beta.9"]), [])

    def test_things_in_the_feed_that_are_not_ours_are_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "appcast.xml")
            with open(path, "w") as handle:
                handle.write(feed("0.1.0-rc.1", "banana", "1.2", "0.1.0-rc.1-extra"))
            self.assertEqual(v.released_in_feed(path), [v.Version(0, 1, 0, "rc", 1)])


class PreviousTagTests(unittest.TestCase):
    TAGS = ["v0.1.0.beta-01", "v0.1.0.rc-01", "v0.1.0", "v0.1.1.rc-01", "v0.1.0-rc.2", "something-else"]

    def previous(self, tag, tags=None):
        return v.previous_tag(v.parse_tag(tag), self.TAGS if tags is None else tags)

    def test_a_release_lists_everything_since_the_previous_release(self):
        self.assertEqual(self.previous("v0.1.1"), "v0.1.0", "not since the release candidate")
        self.assertEqual(self.previous("v0.1.0", ["v0.1.0.beta-01", "v0.1.0.rc-01"]), None, "the first release has no baseline")

    def test_a_pre_release_lists_what_is_new_since_the_previous_tag(self):
        self.assertEqual(self.previous("v0.1.1.rc-02"), "v0.1.1.rc-01")
        self.assertEqual(self.previous("v0.1.0.rc-01"), "v0.1.0.beta-01")
        self.assertEqual(self.previous("v0.1.0.beta-02"), "v0.1.0.beta-01")

    def test_old_style_and_unrelated_tags_are_ignored(self):
        self.assertEqual(self.previous("v0.1.0.beta-01", ["v0.1.0-rc.2", "v0.0.9", "junk"]), "v0.0.9")

    def test_it_never_returns_a_newer_tag(self):
        self.assertEqual(self.previous("v0.1.0.beta-01", ["v0.2.0", "v0.1.0"]), None)


class CommandLineTests(unittest.TestCase):
    def run_main(self, *argv):
        import io
        from contextlib import redirect_stderr, redirect_stdout
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = v.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_fields_prints_and_appends_to_github_output(self):
        with tempfile.TemporaryDirectory() as folder:
            output = os.path.join(folder, "out")
            code, printed, _ = self.run_main("fields", "v0.1.0.rc-01", "--github-output", output)
            self.assertEqual(code, 0)
            with open(output) as handle:
                written = handle.read()
            self.assertIn("build=0.1.0.201", printed)
            self.assertEqual(printed, written)
            self.assertIn("title=PulseEight Control 0.1.0: Release Candidate 1", written)

    def test_a_bad_tag_fails_with_a_message(self):
        code, _, error = self.run_main("fields", "v0.1.0.rc-1")
        self.assertEqual(code, 1)
        self.assertIn("isn't a release tag", error)

    def test_check_reads_the_feeds(self):
        with tempfile.TemporaryDirectory() as folder:
            mac, win = os.path.join(folder, "mac.xml"), os.path.join(folder, "win.xml")
            for path, shorts in [(mac, ["0.1.0-rc.1"]), (win, ["0.1.0-rc.1", "0.1.0-rc.2"])]:
                with open(path, "w") as handle:
                    handle.write(feed(*shorts))
            code, _, error = self.run_main("check", "v0.1.0.rc-02", "--feed", mac, "--feed", win)
            self.assertEqual(code, 1)
            self.assertIn("already released", error)
            self.assertEqual(self.run_main("check", "v0.1.0.rc-03", "--feed", mac, "--feed", win)[0], 0)

    def test_check_with_no_feed_yet_passes_a_valid_tag(self):
        self.assertEqual(self.run_main("check", "v0.1.0")[0], 0)

    def test_dev_fields(self):
        code, printed, _ = self.run_main("dev")
        self.assertEqual(code, 0)
        self.assertIn("semver=0.0.0-dev", printed)


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as handle:
        return handle.read()


class SingleSourceTests(unittest.TestCase):
    """The version is defined by the release tag and by version.py, and nowhere else. These fail if a copy creeps back."""

    def test_there_is_no_version_file_any_more(self):
        self.assertFalse(os.path.exists(os.path.join(ROOT, "VERSION")), "the release tag is the only source of the version")

    def test_the_release_workflow_does_not_read_a_version_file(self):
        self.assertNotIn("< VERSION", read(".github", "workflows", "release.yml"))
        self.assertNotIn("run_number", read(".github", "workflows", "release.yml"), "the build number comes from the tag, not the run")

    def test_the_macos_placeholders_match_a_development_build(self):
        import plistlib
        with open(os.path.join(ROOT, "PulseEightControl-macos", "Info.plist"), "rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleShortVersionString"], v.DEV["semver"])
        self.assertEqual(info["CFBundleVersion"], v.DEV["build"])
        self.assertEqual(info["P8ReleaseChannel"], v.DEV["channel"])
        self.assertEqual(info["P8ReleaseLabel"], v.DEV["label"])

    def test_the_windows_project_defaults_match_a_development_build(self):
        import re
        project = read("PulseEightControl-windows", "App", "PulseEightControl.csproj")
        for name, field in [("P8Version", "semver"), ("P8Build", "build"), ("P8Channel", "channel"), ("P8Label", "label")]:
            default = re.search(rf"<{name} Condition=\"'\$\({name}\)' == ''\">([^<]*)</{name}>", project)
            self.assertIsNotNone(default, f"{name} has no default in the csproj")
            self.assertEqual(default.group(1), v.DEV[field], name)

    def test_the_windows_script_defaults_match_a_development_build(self):
        import re
        for path in [("PulseEightControl-windows", "build.ps1"), ("PulseEightControl-windows", "installer", "build-installer.ps1")]:
            text = read(*path)
            for name, field in [("Version", "semver"), ("Build", "build"), ("Channel", "channel"), ("Label", "label")]:
                default = re.search(rf"\[string\] \${name} = '([^']*)'", text)
                self.assertIsNotNone(default, f"{path[-1]} has no -{name}")
                self.assertEqual(default.group(1), v.DEV[field], f"{path[-1]} -{name}")

    def test_no_release_version_is_written_into_the_build_files(self):
        import re
        literal = re.compile(r"(?<![\w.])\d+\.\d+\.\d+(?:\.\d+)?(?![\w.])")
        allowed = {"0.0.0", "0.0.0.0"}
        files = [("PulseEightControl-macos", "Info.plist"), ("PulseEightControl-macos", "package.sh"),
                 ("PulseEightControl-windows", "App", "PulseEightControl.csproj"), ("PulseEightControl-windows", "build.ps1"),
                 ("PulseEightControl-windows", "installer", "build-installer.ps1"), ("PulseEightControl-windows", "installer", "PulseEightControl.iss")]
        for path in files:
            text = re.sub(r"<#.*?#>", "", read(*path), flags=re.DOTALL)  # PowerShell help blocks
            # Documentation examples (comments) may show a version; code and values may not.
            code = "\n".join(line for line in text.splitlines() if not line.strip().startswith(("#", ";", "<!--", "--", "."))
                             and "<!--" not in line and "-->" not in line
                             and "PackageReference" not in line)  # a package's version isn't this app's
            found = {m for m in literal.findall(code) if m not in allowed}
            # Dotted numbers that aren't versions (a plist's own header version, the minimum OS) are not ours.
            found -= {"1.0", "14.0", "10.0.17763.0", "10.0.19041.0", "8.0.x", "6.4.3", "2.0"}
            self.assertEqual(found, set(), f"{os.path.join(*path)} has a hard-coded version")


if __name__ == "__main__":
    unittest.main()
