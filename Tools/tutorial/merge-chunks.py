#!/usr/bin/env python3
"""Merge translated chunks back into one language table.

Chunks exist so a translator works on a few thousand characters at a time. This
reassembles them into the single file the renderer loads, and refuses to write
unless the result has exactly the same shape as the Chinese source — a missing
or extra key would otherwise show up as a blank section in the built page.
"""

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
I18N = HERE / "i18n"
SOURCE = I18N / "zh-Hans.json"


def shape(node, path=""):
    """Every leaf path in a nested structure, for comparing two tables."""
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
    language = sys.argv[1] if len(sys.argv) > 1 else "en"
    chunk_dir = I18N / "chunks" / language
    if not chunk_dir.exists():
        sys.exit(f"no chunks for {language}: {chunk_dir}")

    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    result = {"articles": {}, "articleIndex": {}, "toolNotes": {},
              "fileNotes": {}, "chrome": {}, "blocks": {}}

    # Articles
    for name in ["a1", "a2", "a3"]:
        path = chunk_dir / f"{name}.out.json"
        if path.exists():
            result["articles"].update(json.loads(path.read_text(encoding="utf-8")))

    # Tool notes
    for name in ["b1", "b2"]:
        path = chunk_dir / f"{name}.out.json"
        if path.exists():
            result["toolNotes"].update(json.loads(path.read_text(encoding="utf-8")))

    # Everything else
    path = chunk_dir / "c1.out.json"
    if path.exists():
        rest = json.loads(path.read_text(encoding="utf-8"))
        for key in ["articleIndex", "fileNotes", "chrome", "blocks"]:
            result[key] = rest.get(key, {})

    # Verify shape against the source before writing.
    problems = []
    for key in result:
        want = shape(source[key], key)
        got = shape(result[key], key)
        if len(want) != len(got):
            problems.append(f"{key}: {len(got)} leaves, expected {len(want)}")
            missing = set(want) - set(got)
            if missing:
                problems.append(f"  missing: {sorted(missing)[:5]}")
        else:
            # Order does not affect rendering; completeness does.
            missing = set(want) - set(got)
            extra = set(got) - set(want)
            if missing:
                problems.append(f"{key}: missing {sorted(missing)[:5]}")
            if extra:
                problems.append(f"{key}: unexpected {sorted(extra)[:5]}")

    if problems:
        print(f"Shape mismatch; {language}.json not written:")
        for p in problems:
            print(f"  {p}")
        return 1

    out = I18N / f"{language}.json"
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")

    total = sum(len(shape(result[k], k)) for k in result)
    print(f"Merged {out.relative_to(HERE.parent.parent)}  ({out.stat().st_size:,} bytes)")
    for key in result:
        print(f"  {key:14s} {len(shape(result[key], key)):4d} leaves")
    print(f"  {'total':14s} {total:4d} leaves")
    return 0


if __name__ == "__main__":
    sys.exit(main())
