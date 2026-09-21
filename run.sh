#!/bin/bash
# Build (if needed) and launch FormatForge.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/FormatForge.app"

if [[ ! -x "$APP/Contents/MacOS/FormatForge" ]]; then
    echo "No built app found; building first…"
    "$ROOT/build.sh"
fi

# Relaunch cleanly so a stale instance never masks a new build.
pkill -f "FormatForge.app/Contents/MacOS/FormatForge" 2>/dev/null || true
sleep 0.5

open "$APP"
echo "Launched: $APP"
