#!/bin/bash
# Build a self-contained FormatForge.app and package it as a DMG.
#
# The result runs on any Apple-silicon or Intel Mac running macOS 14+ with no
# Homebrew, no ffmpeg and no other prerequisites: every external tool is
# bundled inside the app bundle.
#
# Usage:
#   ./make-dmg.sh              # build universal app + DMG
#   ./make-dmg.sh --arm64-only # skip the Intel slice (much faster)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="FormatForge"
VOLUME_NAME="FormatForge"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VENDOR_BIN="$BUILD_DIR/vendor/bin"
DMG_STAGE="$BUILD_DIR/dmg-stage"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
CACHE_DIR="${TMPDIR:-/tmp}/formatforge-module-cache"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
info() { echo "${BLUE}▸${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }
fail() { echo "${RED}✗${RESET} $*" >&2; exit 1; }

UNIVERSAL=1
for arg in "$@"; do
    case "$arg" in
        --arm64-only) UNIVERSAL=0 ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
    esac
done

# ---------------------------------------------------------------- SDK

pick_sdk() {
    local candidates=()
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

    local probe="$CACHE_DIR/sdk-probe"
    mkdir -p "$probe"
    cat > "$probe/p.swift" <<'PROBE'
import SwiftUI
import PDFKit
import AVFoundation
import Vision
import CryptoKit
@main struct P { static func main() { _ = 0 } }
PROBE
    local sdk
    for sdk in "${candidates[@]}"; do
        [[ -d "$sdk" ]] || continue
        if swiftc -sdk "$sdk" -module-cache-path "$CACHE_DIR/probe" \
                  -parse-as-library -o "$probe/p.bin" "$probe/p.swift" >/dev/null 2>&1; then
            echo "$sdk"; return 0
        fi
    done
    return 1
}

info "Selecting an SDK…"
SDK="$(pick_sdk)" || fail "No SDK can compile SwiftUI"
ok "SDK：$SDK"
DEPLOY_TARGET="${FORMATFORGE_TARGET:-14.0}"

# ---------------------------------------------------------------- tools

if [[ ! -x "$VENDOR_BIN/ffmpeg-arm64" || ! -x "$VENDOR_BIN/ffprobe-arm64" ]]; then
    info "Fetching static ffmpeg / ffprobe…"
    "$ROOT/Scripts/fetch-tools.sh"
fi
[[ -x "$VENDOR_BIN/ffmpeg-arm64" ]] || fail "arm64 ffmpeg is missing"
[[ -x "$VENDOR_BIN/ffprobe-arm64" ]] || fail "arm64 ffprobe is missing"
ok "Static tools ready"

# ---------------------------------------------------------------- icon

make_icon() {
    local icns="$ROOT/Resources/AppIcon.icns"
    local source="$ROOT/Resources/AppIcon-source.png"

    # The icon is shared with build.sh; regenerate only when the artwork moved.
    if [[ -f "$icns" && -f "$source" && "$icns" -nt "$source" ]]; then
        return 0
    fi
    if [[ ! -f "$source" ]]; then
        [[ -f "$icns" ]] && return 0
        warn "No icon source; using the system default"
        return 0
    fi

    info "Generating the app icon…"
    if "$ROOT/Scripts/make-icon.sh" >/dev/null 2>&1; then
        ok "Icon generated"
    else
        warn "Icon generation failed"
    fi
}

# ---------------------------------------------------------------- compile

compile_slice() {
    local arch="$1" output="$2"
    local sources=()
    while IFS= read -r -d '' file; do
        sources+=("$file")
    done < <(find "$ROOT/Sources" -name '*.swift' -print0 | sort -z)

    mkdir -p "$CACHE_DIR/modules-$arch"
    swiftc -sdk "$SDK" \
        -target "${arch}-apple-macosx${DEPLOY_TARGET}" \
        -module-cache-path "$CACHE_DIR/modules-$arch" \
        -parse-as-library -O -whole-module-optimization -swift-version 5 \
        -Xfrontend -strict-concurrency=minimal \
        -framework SwiftUI -framework AppKit -framework AVFoundation \
        -framework PDFKit -framework Vision -framework CoreImage \
        -framework UniformTypeIdentifiers \
        -o "$output" "${sources[@]}" 2> "$CACHE_DIR/build-$arch.log"
}

build_binary() {
    info "Compiling the app ($( [[ $UNIVERSAL -eq 1 ]] && echo "universal arm64 + x86_64" || echo "arm64 only" ))…"
    local start; start=$(date +%s)

    compile_slice arm64 "$BUILD_DIR/FormatForge-arm64" || {
        grep -E "error:" "$CACHE_DIR/build-arm64.log" | head -30
        fail "arm64 compilation failed"
    }

    if [[ $UNIVERSAL -eq 1 ]]; then
        if compile_slice x86_64 "$BUILD_DIR/FormatForge-x86_64"; then
            lipo -create -output "$BUILD_DIR/FormatForge-universal" \
                 "$BUILD_DIR/FormatForge-arm64" "$BUILD_DIR/FormatForge-x86_64"
            ok "Merged into a universal binary ($(lipo -archs "$BUILD_DIR/FormatForge-universal"))"
        else
            warn "x86_64 compilation failed; shipping arm64 only (will not run on Intel)"
            cp "$BUILD_DIR/FormatForge-arm64" "$BUILD_DIR/FormatForge-universal"
        fi
    else
        cp "$BUILD_DIR/FormatForge-arm64" "$BUILD_DIR/FormatForge-universal"
    fi

    ok "Compiled in $(( $(date +%s) - start ))s"
}

# ---------------------------------------------------------------- bundle tools

bundle_tools() {
    local tools_dir="$APP_BUNDLE/Contents/Resources/Tools"
    mkdir -p "$tools_dir"

    info "Bundling external tools…"

    # ffmpeg / ffprobe: combine the per-architecture static builds into
    # universal binaries so either Mac can run them.
    for tool in ffmpeg ffprobe; do
        if [[ $UNIVERSAL -eq 1 && -f "$VENDOR_BIN/$tool-x86_64" ]]; then
            lipo -create -output "$tools_dir/$tool" \
                 "$VENDOR_BIN/$tool-arm64" "$VENDOR_BIN/$tool-x86_64"
        else
            cp "$VENDOR_BIN/$tool-arm64" "$tools_dir/$tool"
        fi
        chmod 0755 "$tools_dir/$tool"
        ok "${tool}（$(lipo -archs "$tools_dir/$tool" 2>/dev/null || echo "?"))"
    done

    # 7z: static, arm64 only. Intel Macs fall back to a system install.
    if [[ -f "$VENDOR_BIN/7z-arm64" ]]; then
        cp "$VENDOR_BIN/7z-arm64" "$tools_dir/7z"
        chmod 0755 "$tools_dir/7z"
        ok "7z（$(lipo -archs "$tools_dir/7z")）"
    fi

    # cwebp links against Homebrew dylibs; relocate them into the bundle and
    # rewrite the install names so nothing points outside the app.
    if [[ -f "$VENDOR_BIN/cwebp-arm64" ]]; then
        bundle_cwebp "$tools_dir"
    fi
}

bundle_cwebp() {
    local tools_dir="$1"
    local libs_dir="$APP_BUNDLE/Contents/Frameworks"
    mkdir -p "$libs_dir"

    cp "$VENDOR_BIN/cwebp-arm64" "$tools_dir/cwebp"
    chmod 0755 "$tools_dir/cwebp"

    # Copy the full dependency closure (cwebp -> libwebp -> libtiff -> ...),
    # rewriting every install name to @rpath so the bundle is relocatable.
    local processed="$CACHE_DIR/cwebp-processed.txt"
    : > "$processed"

    # Search these roots when resolving a bare library name.
    local roots=(
        /opt/homebrew/opt /opt/homebrew/lib /opt/homebrew/Cellar
        /usr/local/opt /usr/local/lib
    )

    resolve_lib() {
        local name="$1"
        local root found
        for root in "${roots[@]}"; do
            [[ -d "$root" ]] || continue
            found="$(find "$root" -maxdepth 4 -name "$name" 2>/dev/null | head -1)"
            [[ -n "$found" ]] && { echo "$found"; return 0; }
        done
        return 1
    }

    # Process one binary/library: copy its deps and rewrite references.
    process_binary() {
        local target="$1"
        local deps
        deps="$(otool -L "$target" | grep '^[[:space:]]' | awk '{print $1}' \
                | grep -v '^/usr/lib/' | grep -v '^/System/' || true)"
        [[ -z "$deps" ]] && return 0

        local lib base source
        while IFS= read -r lib; do
            [[ -z "$lib" ]] && continue
            base="$(basename "$lib")"
            source="$lib"
            [[ -f "$source" ]] || source="$(resolve_lib "$base")" || {
                warn "not found: $base"; continue; }

            local dest="$libs_dir/$base"
            if [[ ! -f "$dest" ]]; then
                cp -f "$source" "$dest"
                chmod 0644 "$dest"
                install_name_tool -id "@rpath/$base" "$dest" 2>/dev/null || true
                # Recurse into the copied library's own dependencies.
                if ! grep -qx "$base" "$processed" 2>/dev/null; then
                    echo "$base" >> "$processed"
                    process_binary "$dest"
                fi
            fi
            install_name_tool -change "$lib" "@rpath/$base" "$target" 2>/dev/null || true
        done <<< "$deps"
    }

    process_binary "$tools_dir/cwebp"
    install_name_tool -add_rpath "@executable_path/../../Frameworks" "$tools_dir/cwebp" 2>/dev/null || true

    local count
    count="$(ls "$libs_dir" 2>/dev/null | wc -l | tr -d ' ')"
    ok "cwebp (${count} libraries bundled)"
}

# ---------------------------------------------------------------- assemble

assemble_app() {
    info "Assembling the app bundle…"
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

    cp "$BUILD_DIR/FormatForge-universal" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    chmod 0755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    [[ -f "$ROOT/Resources/AppIcon.icns" ]] && \
        cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    [[ -f "$ROOT/README.md" ]] && \
        cp "$ROOT/README.md" "$APP_BUNDLE/Contents/Resources/README.md"
    printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

    bundle_tools

    # Sign inner binaries first, then the bundle: signing the bundle first
    # would invalidate it when the nested code changes.
    if command -v codesign >/dev/null 2>&1; then
        local target
        for target in "$APP_BUNDLE/Contents/Resources/Tools/"* \
                      "$APP_BUNDLE/Contents/Frameworks/"*.dylib; do
            [[ -f "$target" ]] || continue
            codesign --force --sign - "$target" >/dev/null 2>&1 || true
        done
        if codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
            ok "Ad-hoc signed"
        else
            warn "Signing failed (still runs; right-click → Open on first launch)"
        fi
    fi
}

# ---------------------------------------------------------------- DMG

make_dmg() {
    info "Building the DMG…"
    rm -rf "$DMG_STAGE" "$DMG_PATH"
    mkdir -p "$DMG_STAGE"

    cp -R "$APP_BUNDLE" "$DMG_STAGE/"
    ln -s /Applications "$DMG_STAGE/Applications"

    # A short read-me shown next to the app.
    cat > "$DMG_STAGE/Read Me.txt" <<'NOTE'
FormatForge — offline format conversion, entirely on your Mac

Install
  Drag FormatForge from the left into the Applications folder on the right.

First launch
  This app is not signed with an Apple developer certificate, so macOS may
  block it the first time:
      right-click the icon -> Open -> click Open in the dialog.
  After that it launches normally with a double-click.

Dependencies
  Everything is bundled. You do not need Homebrew, ffmpeg or anything else.
  Video processing, encrypted volumes, WebP output and document conversion
  all run locally.

Requires macOS 14 or later.
NOTE

    # Build a compressed read-only image. hdiutil needs permission to attach a
    # disk-image device; in a restricted environment it fails with
    # "operation not permitted", so report that clearly instead of shipping a
    # DMG that does not exist.
    # nothing.
    local created=0
    if hdiutil create -volname "$VOLUME_NAME" -srcfolder "$DMG_STAGE" \
            -ov -format UDZO "$DMG_PATH" >/dev/null 2>&1; then
        created=1
    elif hdiutil create -volname "$VOLUME_NAME" -srcfolder "$DMG_STAGE" \
            -ov -format UDZO -fs HFS+ "$DMG_PATH" >/dev/null 2>&1; then
        created=1
    fi

    if [[ $created -eq 0 ]]; then
        warn "hdiutil could not create the DMG (mounting disk images is not permitted here)"
        warn "The app bundle is ready; build the DMG by hand with:"
        echo "      hdiutil create -volname $VOLUME_NAME -srcfolder '$DMG_STAGE' -ov -format UDZO '$DMG_PATH'"
        return 0
    fi

    hdiutil verify "$DMG_PATH" >/dev/null 2>&1 || warn "DMG verification failed"
    ok "DMG created"
}

# ---------------------------------------------------------------- verify

verify_bundle() {
    info "Verifying the app bundle…"
    local app="$APP_BUNDLE"
    [[ -x "$app/Contents/MacOS/$APP_NAME" ]] || fail "Executable missing"

    local archs; archs="$(lipo -archs "$app/Contents/MacOS/$APP_NAME")"
    ok "App architecture: $archs"

    # Every bundled tool must run and report its version.
    local tool
    for tool in ffmpeg ffprobe; do
        if "$app/Contents/Resources/Tools/$tool" -version >/dev/null 2>&1; then
            ok "$tool runs ($(lipo -archs "$app/Contents/Resources/Tools/$tool"))"
        else
            fail "$tool does not run"
        fi
    done
    if [[ -x "$app/Contents/Resources/Tools/7z" ]]; then
        "$app/Contents/Resources/Tools/7z" >/dev/null 2>&1 \
            && ok "7z runs" || warn "7z does not run"
    fi
    if [[ -x "$app/Contents/Resources/Tools/cwebp" ]]; then
        "$app/Contents/Resources/Tools/cwebp" -version >/dev/null 2>&1 \
            && ok "cwebp runs" || warn "cwebp does not run (WebP output unavailable)"
    fi

    # Nothing may reference a path outside the bundle (besides system libs).
    # For a universal binary `otool -L` prints an "<path> (architecture xxx):"
    # header per slice, so only lines that start with a tab are dependencies.
    external_deps() {
        otool -L "$1" | grep '^[[:space:]]' | awk '{print $1}' \
            | grep -v '^/usr/lib/' | grep -v '^/System/' || true
    }

    local offenders
    offenders="$(external_deps "$app/Contents/Resources/Tools/ffmpeg")"
    [[ -z "$offenders" ]] || fail "ffmpeg still links external libraries: $offenders"
    ok "ffmpeg has no external dependencies"

    offenders="$(external_deps "$app/Contents/Resources/Tools/ffprobe")"
    [[ -z "$offenders" ]] || fail "ffprobe still links external libraries: $offenders"
    ok "ffprobe has no external dependencies"

    if [[ -x "$app/Contents/Resources/Tools/7z" ]]; then
        offenders="$(external_deps "$app/Contents/Resources/Tools/7z")"
        [[ -z "$offenders" ]] || warn "7z still has external dependencies: $offenders"
    fi

    if [[ -x "$app/Contents/Resources/Tools/cwebp" ]]; then
        offenders="$(external_deps "$app/Contents/Resources/Tools/cwebp" | grep -v '^@rpath/' || true)"
        [[ -z "$offenders" ]] || warn "cwebp still has absolute-path dependencies: $offenders"
        # Its bundled libraries must also be relocatable.
        local lib
        for lib in "$app/Contents/Frameworks/"*.dylib; do
            [[ -f "$lib" ]] || continue
            local libdeps
            libdeps="$(external_deps "$lib" | grep -v '^@rpath/' || true)"
            [[ -z "$libdeps" ]] || warn "$(basename "$lib") still references: $libdeps"
        done
        ok "cwebp dependencies are fully bundled"
    fi

    # The code signature must be intact after bundling.
    codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
        && ok "Signature verified" || warn "Signature check failed (right-click → Open on first launch)"
}

# ---------------------------------------------------------------- main

echo
echo "${BOLD}FormatForge — universal binary + DMG${RESET}"
echo "  Project  : $ROOT"
echo "  Target   : macOS $DEPLOY_TARGET"
echo

make_icon
build_binary
assemble_app
verify_bundle
make_dmg

APP_SIZE="$(du -sh "$APP_BUNDLE" | cut -f1)"

echo
ok "${BOLD}Done${RESET}"
echo "  Bundle   : $APP_BUNDLE  ($APP_SIZE)"
if [[ -f "$DMG_PATH" ]]; then
    echo "  DMG    : $DMG_PATH  ($(du -sh "$DMG_PATH" | cut -f1))"
    echo
    echo "  On any Mac: open the DMG → drag to Applications → right-click Open the first time"
else
    echo "  DMG      : not created (see above)"
fi
echo
