#!/usr/bin/env python3
"""Assign a stable semantic key to every Chinese string in the source tree.

The app ships 12 languages, so strings cannot live in Swift literals: each one
gets a key like `video.convert.param.crf.hint`, and the translations live in
per-language JSON files under Resources/i18n/.

Keys are derived from context (which tool, which parameter, which file) rather
than from the text itself, so editing a translation never changes a key.
"""

import json
import pathlib
import re
from collections import OrderedDict

# This script lives in Tools/i18n/, so the project root is two levels up.
ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SRC = ROOT / "Sources"

STR = re.compile(r'"((?:[^"\\]|\\.)*)"')
CJK = re.compile(r"[\u4e00-\u9fff]")
TOOL_ID = re.compile(r'id:\s*"([a-z]+\.[a-z0-9]+)"')
PARAM = re.compile(r'\.(?:text|number|slider|toggle|picker)\(\s*"([A-Za-z0-9_]+)"')
PRESET = re.compile(r'ToolPreset\(\s*\n?\s*id:\s*"([a-z0-9]+)"')

#: Well-known enumerations that appear as labels.
ENUM_CONTEXT = {
    "ToolCategory": "category",
    "ScalePreset": "scale",
    "AudioCodec": "audio",
    "VideoCodec": "codec",
    "WatermarkPosition": "position",
    "StitchLayout": "stitch",
    "ImageFit": "fit",
    "ArchiveFormat": "archive",
    "DocumentKind": "document",
    "HashAlgorithm": "hash",
    "MediaKind": "mediakind",
    "GifRecipe.Transition": "transition",
    "GifRecipe.FitMode": "giffit",
    "AppSettings.OutputMode": "outputmode",
    "AppSettings.ConflictPolicy": "conflict",
    "JobState": "jobstate",
    "LogEntry.Level": "loglevel",
    "ToolResultKind": "resultkind",
}


def slug(text):
    """Turn a label into a key-safe fragment."""
    text = text.strip()
    # Keep ASCII alphanumerics; map everything else to separators.
    out = re.sub(r"[^A-Za-z0-9]+", "_", text).strip("_").lower()
    return out or "x"


def assign_keys():
    """Walk the sources and produce {key: {"zh":..., "file":..., "line":...}}."""
    mapping = OrderedDict()
    seen_zh = {}

    for path in sorted(SRC.rglob("*.swift")):
        rel = str(path.relative_to(SRC))
        lines = path.read_text(encoding="utf-8").splitlines()

        # Track the enclosing tool / enum / function as we scan.
        current_tool = None
        current_param = None
        current_preset = None
        current_enum = None
        current_enum_case = None
        current_func = None
        tool_depth = 0
        depth = 0

        for i, raw in enumerate(lines, 1):
            line = raw
            stripped = line.strip()

            # Comments never carry UI strings.
            if stripped.startswith("//"):
                continue

            # Update structural context before looking for strings.
            if m := TOOL_ID.search(line):
                current_tool = m.group(1)
                tool_depth = depth
                current_param = None
            if m := PARAM.search(line):
                current_param = m.group(1)
            if m := PRESET.search(line):
                current_preset = m.group(1)
            if m := re.match(r"(?:public |private )?enum (\w+)", stripped):
                current_enum = m.group(1)
            if m := re.match(r"case (\w+)", stripped):
                current_enum_case = m.group(1)
            if m := re.match(r"(?:static )?(?:func|var|let) (\w+)", stripped):
                current_func = m.group(1)

            for sm in STR.finditer(line):
                text = sm.group(1)
                if not CJK.search(text):
                    continue

                # Reuse the key of an identical string seen earlier so the same
                # text is translated once.
                if text in seen_zh:
                    continue

                # Decide the key prefix from context.
                if current_tool and ("name:" in line or "summary:" in line
                                     or "actionTitle" in line):
                    field = ("name" if "name:" in line
                             else "summary" if "summary:" in line
                             else "action")
                    key = f"{current_tool}.{field}"
                elif current_tool and current_param and "hint:" in line:
                    key = f"{current_tool}.param.{current_param}.hint"
                elif current_tool and current_param:
                    key = f"{current_tool}.param.{current_param}.label"
                elif current_preset and "detail" in line:
                    key = f"preset.{slug(current_preset)}.detail"
                elif current_preset:
                    key = f"preset.{slug(current_preset)}.label"
                elif current_enum and current_enum_case and "return" in line:
                    key = f"enum.{ENUM_CONTEXT.get(current_enum, slug(current_enum))}.{slug(current_enum_case)}"
                elif current_func:
                    key = f"{slug(rel.replace('/', '.').replace('.swift', ''))}.{slug(current_func)}.{len(seen_zh)}"
                else:
                    key = f"misc.{len(seen_zh)}"

                # Guarantee uniqueness.
                base = key
                n = 2
                while key in mapping:
                    key = f"{base}.{n}"
                    n += 1

                mapping[key] = {"zh": text, "file": rel, "line": i}
                seen_zh[text] = key

            depth += line.count("{") - line.count("}")

    return mapping, seen_zh


def main():
    mapping, seen_zh = assign_keys()

    # Attach the English translation produced by the translation batches.
    english = {}
    for out in sorted((ROOT / "build/i18n").glob("out*.json")):
        english.update(json.loads(out.read_text(encoding="utf-8")))

    missing = []
    for key, entry in mapping.items():
        entry["en"] = english.get(entry["zh"], "")
        if not entry["en"]:
            missing.append(entry["zh"])

    out = ROOT / "build/i18n/keys.json"
    out.write_text(json.dumps(mapping, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"Assigned {len(mapping)} semantic keys -> {out}")
    print(f"English already present: {sum(1 for e in mapping.values() if e['en'])}")
    if missing:
        print(f"Missing English: {len(missing)}")
        for m in missing[:15]:
            print(f"  {m}")


if __name__ == "__main__":
    main()
