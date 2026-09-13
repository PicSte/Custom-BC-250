#!/usr/bin/env python3
"""Parse every Python file in gui/, so a syntax error fails the lint run.

Deliberately not a style checker: the project has no Python linter configured,
and a broken parse is the one thing that must never reach a commit.
"""

import ast
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
targets = sorted((root / "gui").rglob("*.py")) + [root / "gui" / "bc250-gui"]

failures = 0
for path in targets:
    try:
        ast.parse(path.read_text())
    except SyntaxError as exc:
        print(f"{path.relative_to(root)}: {exc}")
        failures = 1

sys.exit(failures)
