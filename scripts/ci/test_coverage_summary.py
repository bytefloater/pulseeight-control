"""Tests for coverage-summary.py. Run:  python3 -m unittest discover -s scripts/ci -p 'test_*.py'"""

import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("coverage_summary", pathlib.Path(__file__).with_name("coverage-summary.py"))
coverage_summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage_summary)


def report(**files):
    return {"data": [{"files": [{"filename": name, "summary": {"lines": {"covered": c, "count": n}}} for name, (c, n) in files.items()]}]}


class SummariseTests(unittest.TestCase):
    def test_sums_shipped_code_and_ignores_tests_and_build_folders(self):
        rows, covered, total = coverage_summary.summarise(report(**{
            "/r/Kit/Sources/A.swift": (8, 10),
            "/r/Kit/Sources/B.swift": (2, 10),
            "/r/Kit/Tests/ATests.swift": (100, 100),
            "/r/Kit/.build/checkouts/Dep/D.swift": (0, 500),
        }))
        self.assertEqual((covered, total), (10, 20))
        self.assertEqual(sorted(r[0] for r in rows), ["/r/Kit/Sources/A.swift", "/r/Kit/Sources/B.swift"])

    def test_include_keeps_only_the_packages_own_sources(self):
        rows, covered, total = coverage_summary.summarise(report(**{
            "/r/App/Sources/View.swift": (1, 4),
            "/r/Kit/Sources/Core.swift": (10, 10),
        }), include=("App/Sources",))
        self.assertEqual((covered, total), (1, 4))
        self.assertEqual([r[0] for r in rows], ["/r/App/Sources/View.swift"])

    def test_an_empty_report_is_fully_covered_not_a_division_by_zero(self):
        rows, covered, total = coverage_summary.summarise({"data": []})
        self.assertEqual((rows, covered, total), ([], 0, 0))
        self.assertEqual(coverage_summary.percent(covered, total), 100.0)


class MarkdownTests(unittest.TestCase):
    def test_lists_the_least_covered_files_first_with_short_paths(self):
        rows, covered, total = coverage_summary.summarise(report(**{
            "/r/PulseEightKit/Sources/Good.swift": (9, 10),
            "/r/PulseEightKit/Sources/Bad.swift": (1, 10),
        }))
        text = coverage_summary.markdown(rows, covered, total, "Kit", 5, ["PulseEightKit/"])
        self.assertIn("### Swift coverage: Kit", text)
        self.assertIn("**50.0%** of 20 lines", text)
        self.assertLess(text.index("Bad.swift"), text.index("Good.swift"))
        self.assertIn("`Sources/Bad.swift`", text)
        self.assertNotIn("/r/", text)

    def test_zero_asks_for_no_file_table(self):
        rows, covered, total = coverage_summary.summarise(report(**{"/r/Sources/A.swift": (1, 2)}))
        self.assertNotIn("| File", coverage_summary.markdown(rows, covered, total, "", 0, []))


if __name__ == "__main__":
    unittest.main()
