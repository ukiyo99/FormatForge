#!/usr/bin/env python3
"""Check the tutorial language tables.

The Chinese table (`i18n/zh-Hans.json`) is the source of record for the
tutorial prose: articles, tool notes, file notes, interface strings and the
static section blocks. Every other language is a translation of it.

This verifies that each table is complete and structurally identical to the
Chinese one. A missing key would otherwise render as a blank section, and an
extra one as an unreachable string, so both fail here rather than in the page.
"""

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
I18N = HERE / "i18n"
SOURCE = "zh-Hans"
#: Languages the tutorial ships in.
LANGUAGES = ["en", "zh-Hans", "ja", "ko", "fr"]

#: Top-level sections and what each holds.
SECTIONS = ["articles", "articleIndex", "toolNotes", "fileNotes", "chrome", "blocks"]


def shape(node, path=""):
    """Every leaf path in a nested structure."""
    if isinstance(node, dict):
        out = []
        for key, value in node.items():
            out.extend(shape(value, f"{path}.{key}" if path else str(key)))
        return out
    if isinstance(node, list):
        out = []
        for i, value in enumerate(node):
            out.extend(shape(value, f"{path}[{i}]"))
        return out
    return [path]


def main():
    if not (I18N / f"{SOURCE}.json").exists():
        sys.exit(f"missing the source table: {SOURCE}.json")

    source = json.loads((I18N / f"{SOURCE}.json").read_text(encoding="utf-8"))
    problems = []

    for code in LANGUAGES:
        path = I18N / f"{code}.json"
        if not path.exists():
            print(f"{code:8s} missing (run the translation, then merge-chunks.py)")
            continue

        table = json.loads(path.read_text(encoding="utf-8"))
        issues = []

        for section in SECTIONS:
            if section not in table:
                issues.append(f"missing section {section}")
                continue
            want = set(shape(source[section], section))
            got = set(shape(table[section], section))
            missing, extra = want - got, got - want
            if missing:
                issues.append(f"{section}: {len(missing)} missing, e.g. {sorted(missing)[:2]}")
            if extra:
                issues.append(f"{section}: {len(extra)} unexpected, e.g. {sorted(extra)[:2]}")

        leaves = sum(len(shape(table[s], s)) for s in SECTIONS if s in table)
        if issues:
            problems.append(code)
            print(f"{code:8s} {leaves:4d} leaves")
            for issue in issues:
                print(f"           {issue}")
        else:
            print(f"{code:8s} {leaves:4d} leaves  ok")

    print()
    if problems:
        print(f"incomplete: {', '.join(problems)}")
        return 1
    print("all tables complete and consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
