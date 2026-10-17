#!/usr/bin/env python3
"""Runs the Python tests for the helper scripts (scripts/ci and scripts/release) in one go.

    python3 scripts/run-tests.py

`unittest discover` takes one folder at a time, so this is the single command that VS Code, CI and people use.
"""

import pathlib
import sys
import unittest

root = pathlib.Path(__file__).resolve().parent
suite = unittest.TestSuite()
for folder in ("ci", "release"):
    suite.addTests(unittest.defaultTestLoader.discover(str(root / folder), pattern="test_*.py"))

result = unittest.TextTestRunner(verbosity=1).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
