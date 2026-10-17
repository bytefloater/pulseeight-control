"""Tests for check-pinned-actions.py (no network: the remote lookup is replaced)."""

import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("check_pinned_actions", pathlib.Path(__file__).with_name("check-pinned-actions.py"))
cpa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cpa)

GOOD = "a" * 40
OTHER = "b" * 40


def lookup_for(table):
    return lambda repo, tag: table.get((repo, tag), set())


class CheckTests(unittest.TestCase):
    def test_a_correct_pin_passes(self):
        text = f"      - uses: actions/checkout@{GOOD} # v7.0.1\n"
        self.assertEqual(cpa.check(text, lookup_for({("actions/checkout", "v7.0.1"): {GOOD}})), [])

    def test_an_annotated_tag_is_accepted_by_the_commit_it_wraps(self):
        text = f"uses: a/b@{GOOD} # v1\n"
        self.assertEqual(cpa.check(text, lookup_for({("a/b", "v1"): {OTHER, GOOD}})), [])

    def test_a_pin_that_is_not_the_named_release_is_reported(self):
        text = f"uses: a/b@{GOOD} # v1\n"
        problems = cpa.check(text, lookup_for({("a/b", "v1"): {OTHER}}))
        self.assertEqual(len(problems), 1)
        self.assertIn("is not v1", problems[0])

    def test_an_unknown_tag_is_reported(self):
        self.assertIn("has no tag v9", cpa.check(f"uses: a/b@{GOOD} # v9\n", lookup_for({}))[0])

    def test_an_unpinned_action_is_reported(self):
        self.assertIn("not pinned", cpa.check("uses: actions/checkout@v4\n", lookup_for({}))[0])

    def test_a_pin_without_a_version_comment_is_reported(self):
        self.assertIn("no version comment", cpa.check(f"uses: a/b@{GOOD}\n", lookup_for({}))[0])

    def test_actions_in_subfolders_and_local_ones_are_handled(self):
        text = f"uses: owner/repo/sub/dir@{GOOD} # v2\n  - uses: ./local-action\n  - uses: docker://alpine:3\n"
        self.assertEqual(cpa.check(text, lookup_for({("owner/repo", "v2"): {GOOD}})), [])


if __name__ == "__main__":
    unittest.main()
