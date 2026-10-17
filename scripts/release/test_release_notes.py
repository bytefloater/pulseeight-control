"""Tests for release_notes.py (no git needed: the log is passed in)."""

import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("release_notes", pathlib.Path(__file__).with_name("release_notes.py"))
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class RenderTests(unittest.TestCase):
    def test_html_lists_each_item_and_escapes_markup(self):
        text = notes.render_html(["Fix <script>alert(1)</script> & more", "Add “quotes”"])
        self.assertIn("<li>Fix &lt;script&gt;alert(1)&lt;/script&gt; &amp; more</li>", text)
        self.assertNotIn("<script>", text)
        self.assertTrue(text.startswith("<ul>") and text.endswith("</ul>"))

    def test_an_empty_release_still_says_something(self):
        self.assertIn("Maintenance release", notes.render_html([]))
        self.assertIn("Maintenance release", notes.render_markdown([]))

    def test_markdown_is_a_bullet_list(self):
        self.assertEqual(notes.render_markdown(["One", "Two"]), "- One\n- Two")

    def test_work_in_progress_and_fixup_commits_are_skipped(self):
        for subject in ["fixup! Add a thing", "WIP: half done", "wip", "squash! tidy"]:
            self.assertTrue(notes.SKIPPED.match(subject), subject)
        for subject in ["Fix the wip counter", "Add fixup handling"]:
            self.assertFalse(notes.SKIPPED.match(subject), subject)


if __name__ == "__main__":
    unittest.main()
