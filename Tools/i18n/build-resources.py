#!/usr/bin/env python3
"""Build the per-language JSON resource files shipped inside the app bundle.

Input:  build/i18n/keys.json      (key -> {zh, en, file, line})
        build/i18n/lang_*.json    (zh text -> translation, from the translators)
Output: Resources/i18n/<code>.json  (key -> translation)

English comes from the compiled-in source strings, so `en.json` is generated
from `keys.json` directly. Every other language is looked up by its Chinese
source text, which is how the translation batches were keyed.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
KEYS = ROOT / "build/i18n/keys.json"
OUT = ROOT / "Resources/i18n"

#: Language code -> file in build/i18n holding its translations.
LANGUAGE_FILES = {
    "zh-Hans": None,          # Simplified Chinese is the source language
    "zh-Hant": "lang_zh-Hant.json",
    "ja": "lang_ja.json",
    "ko": "lang_ko.json",
    "fr": "lang_fr.json",
    "de": "lang_de.json",
    "es": "lang_es.json",
    "pt": "lang_pt.json",
    "ru": "lang_ru.json",
    "it": "lang_it.json",
    "nl": "lang_nl.json",
}


def main():
    if not KEYS.exists():
        sys.exit("run Tools/i18n/assign-keys.py first")
    keys = json.loads(KEYS.read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)

    # English is derived from the keys table itself.
    english = {key: entry["en"] for key, entry in keys.items() if entry.get("en")}
    (OUT / "en.json").write_text(
        json.dumps(english, ensure_ascii=False, indent=1, sort_keys=True),
        encoding="utf-8")
    print(f"en.json        {len(english):5d} keys")

    # Simplified Chinese: key -> the original Chinese text.
    simplified = {key: entry["zh"] for key, entry in keys.items()}
    (OUT / "zh-Hans.json").write_text(
        json.dumps(simplified, ensure_ascii=False, indent=1, sort_keys=True),
        encoding="utf-8")
    print(f"zh-Hans.json   {len(simplified):5d} keys")

    problems = []
    for code, filename in LANGUAGE_FILES.items():
        if filename is None:
            continue
        path = ROOT / "build/i18n" / filename
        if not path.exists():
            problems.append(f"{code}: {filename} missing (not translated yet)")
            continue

        by_text = json.loads(path.read_text(encoding="utf-8"))
        table = {}
        missing = []
        for key, entry in keys.items():
            text = by_text.get(entry["zh"])
            if text is None:
                missing.append(entry["zh"])
                # Fall back to English so the UI is never blank.
                text = entry.get("en", entry["zh"])
            table[key] = text

        (OUT / f"{code}.json").write_text(
            json.dumps(table, ensure_ascii=False, indent=1, sort_keys=True),
            encoding="utf-8")
        status = f"{len(table):5d} keys"
        if missing:
            status += f"  ({len(missing)} fell back to English)"
            problems.append(f"{code}: {len(missing)} untranslated")
        print(f"{code+'.json':15s}{status}")

    if problems:
        print("\nNotes:")
        for p in problems:
            print(f"  {p}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
