#!/usr/bin/env python3
"""Split the tutorial language table into chunks small enough to translate.

Each chunk is a JSON file with the same nesting as the source, so a translator
works on real structure rather than a flat list of fragments — the prose has
<b> markup and code references that must survive translation intact.
"""

import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
I18N = HERE / "i18n"
SOURCE = I18N / "zh-Hans.json"

CHUNKS = {
    "a1": ("articles", ["arch", "pipeline", "ffmpeg", "gif"]),
    "a2": ("articles", ["markdown", "hash", "inspect", "image"]),
    "a3": ("articles", ["estimate", "design", "dmg"]),
    "b1": ("toolNotes", None),      # all, split below by index
    "c1": ("mixed", None),
}


def main():
    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    language = sys.argv[1] if len(sys.argv) > 1 else "en"

    out_dir = I18N / "chunks" / language
    out_dir.mkdir(parents=True, exist_ok=True)

    # --- article chunks ---------------------------------------------------
    for name, ids in [("a1", ["arch", "pipeline", "ffmpeg", "gif"]),
                      ("a2", ["markdown", "hash", "inspect", "image"]),
                      ("a3", ["estimate", "design", "dmg"])]:
        chunk = {aid: data["articles"][aid] for aid in ids}
        (out_dir / f"{name}.json").write_text(
            json.dumps(chunk, ensure_ascii=False, indent=1), encoding="utf-8")

    # --- tool notes, split in half ---------------------------------------
    notes = data["toolNotes"]
    keys = list(notes)
    half = (len(keys) + 1) // 2
    for name, subset in [("b1", keys[:half]), ("b2", keys[half:])]:
        chunk = {k: notes[k] for k in subset}
        (out_dir / f"{name}.json").write_text(
            json.dumps(chunk, ensure_ascii=False, indent=1), encoding="utf-8")

    # --- everything else --------------------------------------------------
    rest = {
        "articleIndex": data["articleIndex"],
        "fileNotes": data["fileNotes"],
        "chrome": data["chrome"],
        "blocks": data["blocks"],
    }
    (out_dir / "c1.json").write_text(
        json.dumps(rest, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"Chunks written to {out_dir.relative_to(HERE.parent.parent)}:")
    for path in sorted(out_dir.glob("*.json")):
        size = path.stat().st_size
        print(f"  {path.name}  {size:7,} bytes")


if __name__ == "__main__":
    main()
