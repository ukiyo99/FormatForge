#!/bin/bash
# Regenerate the HTML tutorial from the current source tree.
#
# Steps: dump the live tool registry to JSON, then render the site. Both steps
# read the real code, so the document cannot drift from the implementation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CACHE_DIR="${TMPDIR:-/tmp}/formatforge-module-cache"
SDK="${FORMATFORGE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || { echo "✗ SDK not found: $SDK" >&2; exit 1; }

mkdir -p build "$CACHE_DIR/dumpreg"

echo "▸ Exporting the tool registry…"
SOURCES=$(find Sources -name '*.swift' ! -name 'FormatForgeApp.swift' | sort | tr '\n' ' ')
swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 \
    -module-cache-path "$CACHE_DIR/dumpreg" \
    -parse-as-library -swift-version 5 -Xfrontend -strict-concurrency=minimal \
    -framework SwiftUI -framework AppKit -framework AVFoundation -framework PDFKit \
    -framework Vision -framework CoreImage -framework UniformTypeIdentifiers \
    -o "$CACHE_DIR/dumpreg-bin" Tools/DumpRegistry.swift $SOURCES \
    2> "$CACHE_DIR/dumpreg.log" || {
        grep -E "error:" "$CACHE_DIR/dumpreg.log" | head -10
        echo "✗ Registry export failed to compile" >&2
        exit 1
    }
"$CACHE_DIR/dumpreg-bin" > build/registry.json
echo "  ✓ $(python3 -c "import json;print(json.load(open('build/registry.json'))['toolCount'])") tools"

echo "▸ Checking the language tables…"
python3 "$ROOT/Tools/tutorial/validate-content.py" | sed 's/^/  /'

echo "▸ Rendering the tutorial…"
python3 Tools/build-tutorial.py
