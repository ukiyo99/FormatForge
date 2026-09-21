#!/bin/bash
# Fetch the static ffmpeg/ffprobe builds used to make the DMG self-contained.
#
# The Homebrew ffmpeg links against ~18 dylibs by absolute path, so it cannot
# simply be copied into an app bundle. These builds are statically linked
# (zero non-system dependencies), so they work on any Mac.
#
# Downloads are cached under build/vendor and verified before use.

set -euo pipefail

# Resolve the project root (this script lives in Scripts/).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/build/vendor"
CACHE="$VENDOR/cache"
OUT="$VENDOR/bin"

mkdir -p "$CACHE" "$OUT"

# name|url|expected-arch
SOURCES=(
    "ffmpeg-arm64|https://www.osxexperts.net/ffmpeg9arm.zip|arm64"
    "ffprobe-arm64|https://www.osxexperts.net/ffprobe9arm.zip|arm64"
    "ffmpeg-x86_64|https://evermeet.cx/ffmpeg/getrelease/zip|x86_64"
    "ffprobe-x86_64|https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip|x86_64"
)

echo "▸ Preparing static ffmpeg / ffprobe…"

for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url arch <<< "$entry"
    binary="${name%%-*}"
    target_arch="${name##*-}"
    archive="$CACHE/$name.zip"

    if [[ ! -s "$archive" ]]; then
        echo "  Downloading $name …"
        if ! curl -sSL --fail --max-time 600 -o "$archive" "$url"; then
            rm -f "$archive"
            echo "  ✗ Download failed: $url" >&2
            exit 1
        fi
    fi

    # Extract into a scratch dir so we can validate before installing.
    scratch="$CACHE/$name-extract"
    rm -rf "$scratch"; mkdir -p "$scratch"
    if ! unzip -o -q "$archive" -d "$scratch"; then
        echo "  ✗ Extraction failed: $archive" >&2
        exit 1
    fi

    src="$scratch/$binary"
    if [[ ! -f "$src" ]]; then
        # Some archives nest the binary.
        src="$(find "$scratch" -type f -name "$binary" | head -1)"
    fi
    if [[ ! -f "$src" ]]; then
        echo "  ✗ $binary not found in the archive" >&2
        exit 1
    fi

    actual="$(lipo -archs "$src" 2>/dev/null || echo unknown)"
    if [[ "$actual" != *"$target_arch"* ]]; then
        echo "  ✗ Wrong architecture: expected ${target_arch}, got $actual" >&2
        exit 1
    fi

    # Reject anything that would need Homebrew at runtime. `grep -c` returning
    # 1 on no-match would abort under `set -e`, so tolerate a non-zero status.
    external_libs="$(otool -L "$src" | tail -n +2 | awk '{print $1}' \
        | grep -v '^/usr/lib/' | grep -v '^/System/' || true)"
    external="$(printf '%s' "$external_libs" | grep -c . || true)"
    if [[ "${external:-0}" != "0" ]]; then
        echo "  ✗ $name still has $external non-system dependencies; cannot bundle" >&2
        printf '%s\n' "$external_libs" | sed 's/^/      /' >&2
        exit 1
    fi

    install -m 0755 "$src" "$OUT/$binary-$target_arch"
    echo "  ✓ $binary-${target_arch} (${actual}, statically linked)"
done

# 7z from Homebrew ships as a shell wrapper pointing at the real binary, so we
# resolve the target and bundle that instead. The real binary is static.
if command -v 7z >/dev/null 2>&1; then
    seven="$(command -v 7z)"
    # Follow the wrapper: `#!/bin/sh\n"/path/to/7z" "$@"`
    if head -c 2 "$seven" | grep -q '#!'; then
        resolved="$(sed -n 's/^"\(.*\)" "\$@".*/\1/p' "$seven" | head -1)"
        [[ -n "$resolved" && -f "$resolved" ]] && seven="$resolved"
    fi
    if file "$seven" | grep -q "Mach-O"; then
        install -m 0755 "$seven" "$OUT/7z-arm64"
        echo "  ✓ 7z-arm64 (static, from Homebrew p7zip)"
    else
        echo "  ! No bundlable 7z binary found; skipping" >&2
    fi
fi

# cwebp is small and its dylibs are relocatable; bundle them together.
if command -v cwebp >/dev/null 2>&1; then
    cp -f "$(command -v cwebp)" "$OUT/cwebp-arm64"
    chmod 0755 "$OUT/cwebp-arm64"
    echo "  ✓ cwebp-arm64 (library paths rewritten later)"
fi

echo "▸ Static tools ready: $OUT"
ls -la "$OUT"
