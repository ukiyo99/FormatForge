#!/bin/bash
# Build FormatForge.app — a self-contained SwiftUI macOS application.
#
# Notes on the toolchain:
#   * This machine's default SDK (MacOSX27.0) is built with a different Swift
#     compiler build than /usr/bin/swiftc, so it cannot compile SwiftUI.
#     We therefore pin an SDK that is known to work, and verify it first.
#   * SwiftPM cannot run here (its manifest compilation is blocked by the
#     sandbox), so we invoke swiftc directly over the source tree.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="FormatForge"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
CACHE_DIR="${TMPDIR:-/tmp}/formatforge-module-cache"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

info()  { echo "${BLUE}▸${RESET} $*"; }
ok()    { echo "${GREEN}✓${RESET} $*"; }
warn()  { echo "${YELLOW}!${RESET} $*"; }
fail()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------- SDK selection

pick_sdk() {
    local candidates=()
    # Prefer explicit overrides, then known-good versions, then the default.
    [[ -n "${FORMATFORGE_SDK:-}" ]] && candidates+=("$FORMATFORGE_SDK")
    candidates+=(
        "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
        "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
        "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
        "/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk"
        "/Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk"
    )
    local default_sdk
    default_sdk="$(xcrun --show-sdk-path 2>/dev/null || true)"
    [[ -n "$default_sdk" ]] && candidates+=("$default_sdk")

    local probe_dir="$CACHE_DIR/sdk-probe"
    mkdir -p "$probe_dir"
    cat > "$probe_dir/probe.swift" <<'PROBE'
import SwiftUI
import PDFKit
import AVFoundation
import Vision
import CryptoKit
import Compression
@main struct Probe { static func main() { _ = 0 } }
PROBE

    local sdk
    for sdk in "${candidates[@]}"; do
        [[ -d "$sdk" ]] || continue
        if swiftc -sdk "$sdk" -module-cache-path "$CACHE_DIR/probe" \
                  -parse-as-library -o "$probe_dir/probe.bin" \
                  "$probe_dir/probe.swift" >/dev/null 2>&1; then
            echo "$sdk"
            return 0
        fi
    done
    return 1
}

info "Selecting a usable macOS SDK…"
SDK="$(pick_sdk)" || fail "No SDK can compile SwiftUI.
  Every candidate path failed. Install the full Xcode, or point
  FORMATFORGE_SDK at a working SDK."
ok "Using SDK: $SDK"

DEPLOY_TARGET="${FORMATFORGE_TARGET:-14.0}"

# ---------------------------------------------------------------- Icon

make_icon() {
    local icns="$ROOT/Resources/AppIcon.icns"
    local source="$ROOT/Resources/AppIcon-source.png"

    # Regenerate when the artwork is newer than the compiled icon, so replacing
    # AppIcon-source.png is all it takes to change the app icon.
    if [[ -f "$icns" && -f "$source" && "$icns" -nt "$source" ]]; then
        return 0
    fi
    if [[ ! -f "$source" ]]; then
        [[ -f "$icns" ]] && return 0
        warn "No Resources/AppIcon-source.png; using the system default icon"
        return 0
    fi

    info "Generating the app icon…"
    if "$ROOT/Scripts/make-icon.sh" >/dev/null 2>&1; then
        ok "Icon generated"
    else
        warn "Icon generation failed; using the system default"
    fi
}

# ---------------------------------------------------------------- Compile

compile() {
    info "Collecting sources…"
    local sources=()
    while IFS= read -r -d '' file; do
        sources+=("$file")
    done < <(find "$ROOT/Sources" -name '*.swift' -print0 | sort -z)

    local count=${#sources[@]}
    [[ $count -gt 0 ]] || fail "No Swift sources found under Sources/"
    ok "$count source files"

    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
    mkdir -p "$CACHE_DIR/modules"

    local flags=(
        -sdk "$SDK"
        -target "arm64-apple-macosx$DEPLOY_TARGET"
        -module-cache-path "$CACHE_DIR/modules"
        -parse-as-library
        -O
        -whole-module-optimization
        -swift-version 5
        -Xfrontend -strict-concurrency=minimal
        -framework SwiftUI
        -framework AppKit
        -framework AVFoundation
        -framework PDFKit
        -framework Vision
        -framework CoreImage
        -framework UniformTypeIdentifiers
    )

    info "Compiling (optimised)…"
    local start
    start=$(date +%s)

    if ! swiftc "${flags[@]}" -o "$MACOS_DIR/$APP_NAME" "${sources[@]}" 2> "$CACHE_DIR/build.log"; then
        echo
        # Surface only the errors; full log stays on disk.
        grep -E "error:" "$CACHE_DIR/build.log" | head -60 || true
        echo
        fail "Compilation failed. Full log: $CACHE_DIR/build.log"
    fi

    local elapsed=$(( $(date +%s) - start ))
    ok "Compiled in ${elapsed}s"
}

# ---------------------------------------------------------------- Bundle

assemble() {
    info "Assembling the app bundle…"
    cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
    if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
        cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    fi

    # Language tables: every <code>.json under Resources/i18n becomes
    # Contents/Resources/i18n/<code>.json, which is where LanguageStore looks.
    if [[ -d "$ROOT/Resources/i18n" ]]; then
        mkdir -p "$RESOURCES_DIR/i18n"
        cp "$ROOT/Resources/i18n"/*.json "$RESOURCES_DIR/i18n/" 2>/dev/null || true
        local count
        count="$(ls "$RESOURCES_DIR/i18n" | wc -l | tr -d ' ')"
        ok "Bundled ${count} languages"
    fi

    # Bundle a short README so the app is self-documenting.
    if [[ -f "$ROOT/README.md" ]]; then
        cp "$ROOT/README.md" "$RESOURCES_DIR/README.md"
    fi

    printf 'APPL????' > "$CONTENTS/PkgInfo"

    # Ad-hoc signature: enough for local use without a Developer ID.
    if codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
        ok "Ad-hoc signed"
    else
        warn "Signing failed (the app still runs; right-click → Open on first launch)"
    fi
}

# ---------------------------------------------------------------- Main

echo
echo "${BOLD}FormatForge build${RESET}"
echo "  Root     : $ROOT"
echo "  Target   : macOS $DEPLOY_TARGET (arm64)"
echo

rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR"

make_icon
compile
assemble

# Verify the binary actually links and starts.
info "Verifying the executable…"
if [[ ! -x "$MACOS_DIR/$APP_NAME" ]]; then
    fail "Executable missing"
fi

# Confirm the binary is a valid Mach-O for the target architecture. We never
# *run* it: this is a GUI app, so launching it would open a window and hang
# the build (and interrupt whatever the user is doing).
if ! file "$MACOS_DIR/$APP_NAME" | grep -q "Mach-O"; then
    fail "Executable is not a valid Mach-O"
fi
ARCHS="$(lipo -archs "$MACOS_DIR/$APP_NAME" 2>/dev/null || echo unknown)"
if [[ "$ARCHS" != *arm64* ]]; then
    fail "Unexpected executable architecture: $ARCHS"
fi
ok "Executable verified (arch ${ARCHS})"

SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo
ok "${BOLD}Build succeeded${RESET}"
echo "  Bundle   : $APP_BUNDLE"
echo "  Size     : $SIZE"
echo
echo "  Run      : open \"$APP_BUNDLE\""
echo
